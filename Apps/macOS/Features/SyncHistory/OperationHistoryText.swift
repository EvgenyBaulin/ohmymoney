import AppCore
import Foundation

/// One event of the tab «История» as the screen draws it: what happened, on which device and
/// when, and the fields that changed in words.
struct OperationHistoryRow: Identifiable, Equatable {
  var id: Int64
  /// «Изменена · MacBook».
  var title: String
  /// «17 сент., 14:32».
  var when: String
  /// «Описание: кофе → латте».
  var lines: [String]
}

/// Turns the journal's events of one operation into words. Pure: the names of records, the
/// texts and the formats come in from the caller, so the tests run it without a window.
///
/// Hidden accounts (0541): while they are covered, an account or a card among `hidden` is
/// named «скрытый счёт» / «скрытая карта», never by its name.
struct OperationHistoryText {
  /// The names of the records a field may point at; `nil` when the record is gone.
  struct Names {
    var account: (UUID) -> String? = { _ in nil }
    var card: (UUID) -> String? = { _ in nil }
    var category: (UUID) -> String? = { _ in nil }
    var place: (UUID) -> String? = { _ in nil }
    var person: (UUID) -> String? = { _ in nil }
    var event: (UUID) -> String? = { _ in nil }
    var goal: (UUID) -> String? = { _ in nil }
  }

  var names = Names()
  var hiddenAccounts: Set<UUID> = []
  var hiddenCards: Set<UUID> = []
  /// The id of this device: its events say «этот Mac» when it has no name.
  var ownDeviceId: String?
  /// The text of a key of the catalog `SyncHistory`.
  var text: (String) -> String
  /// An amount in its currency, to the kopeck.
  var money: (AmountE4, CurrencyCode) -> String
  /// A moment: «17 сент., 14:32».
  var moment: (Date) -> String
  /// The currency of the operation's amounts (its own, or of the part's operation).
  var currency: CurrencyCode = .rub

  /// The fields shown by name, in the order they are listed; any other changed field is
  /// counted in «ещё N».
  static let shownFields: [String] = [
    "kind", "occurred_at", "amount_e4", "currency", "note", "category_id", "payment_method_id",
    "card_id", "place_id", "for_whom", "for_person_id", "event_id", "goal_id", "cashback_e4",
    "quality", "period_month",
  ]

  /// Fields that follow from others and say nothing new: never shown nor counted.
  static let quietFields: Set<String> = [
    "amount_rub_e4", "amount_expr", "rate", "rate_date", "rate_source", "rate_provisional",
    "category_source", "quality_source", "dedup_key", "transaction_id", "cashback_currency",
  ]

  static func storedInstant(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    if let date = formatter.date(from: raw) { return date }
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: String(raw.prefix(19)))
  }

  func rows(_ events: [HistoryEvent]) -> [OperationHistoryRow] {
    events.map { event in
      OperationHistoryRow(
        id: event.id, title: "\(kindText(event.kind)) · \(device(event))",
        when: event.at.date.map(moment) ?? event.at.text, lines: lines(event.changes))
    }
  }

  func device(_ event: HistoryEvent) -> String {
    if !event.deviceName.isEmpty { return event.deviceName }
    return event.deviceId == ownDeviceId
      ? text("history.device.this") : text("history.device.other")
  }

  func kindText(_ kind: HistoryEvent.Kind) -> String {
    switch kind {
    case .created: text("history.kind.created")
    case .edited: text("history.kind.edited")
    case .deleted: text("history.kind.deleted")
    case .restored: text("history.kind.restored")
    }
  }

  func lines(_ changes: [FieldChange]) -> [String] {
    var out: [String] = []
    var others = 0
    let ordered = changes.sorted { left, right in
      let a = Self.shownFields.firstIndex(of: left.field) ?? Int.max
      let b = Self.shownFields.firstIndex(of: right.field) ?? Int.max
      return a < b
    }
    for change in ordered {
      switch change.change {
      case .partAdded: out.append(text("history.part.added"))
      case .partRemoved: out.append(text("history.part.removed"))
      case .value(let before, let after):
        if Self.quietFields.contains(change.field) { continue }
        guard Self.shownFields.contains(change.field) else {
          others += 1
          continue
        }
        let label = text("history.field.\(change.field)")
        let prefix = change.scope == .operation ? "" : text("history.part.prefix") + " "
        out.append(
          "\(prefix)\(label): \(value(before, field: change.field)) → \(value(after, field: change.field))"
        )
      }
    }
    if others > 0 { out.append(String(format: text("history.more"), others)) }
    return out
  }

  func value(_ value: SyncValue, field: String) -> String {
    switch value {
    case .null: return "—"
    case .bool(let flag): return flag ? text("history.yes") : text("history.no")
    case .int(let number):
      if field.hasSuffix("_e4") { return money(AmountE4(raw: number), currency) }
      return String(number)
    case .string(let raw):
      return string(raw, field: field)
    }
  }

  private func string(_ raw: String, field: String) -> String {
    let id = UUID(uuidString: raw)
    switch field {
    case "payment_method_id":
      guard let id else { return raw }
      if hiddenAccounts.contains(id) { return text("history.hidden.account") }
      return names.account(id) ?? text("history.gone")
    case "card_id":
      guard let id else { return raw }
      if hiddenCards.contains(id) { return text("history.hidden.card") }
      return names.card(id) ?? text("history.gone")
    case "category_id": return id.flatMap(names.category) ?? text("history.gone")
    case "place_id": return id.flatMap(names.place) ?? text("history.gone")
    case "for_person_id": return id.flatMap(names.person) ?? text("history.gone")
    case "event_id": return id.flatMap(names.event) ?? text("history.gone")
    case "goal_id": return id.flatMap(names.goal) ?? text("history.gone")
    case "kind", "for_whom", "quality":
      let key = "history.\(field).\(raw)"
      let translated = text(key)
      return translated == key ? raw : translated
    case "occurred_at":
      // Stored as «YYYY-MM-DD HH:MM:SS.SSS» in UTC.
      return Self.storedInstant(raw).map(moment) ?? String(raw.prefix(16))
    default:
      return raw
    }
  }
}
