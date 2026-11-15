import AppCore
import Foundation

/// The two switches of the place features on this phone, both off until the owner turns them on.
/// They are of the device, not of the books: they are not in the database, not in a backup of the
/// books and not sent to another device — like the marks themselves.
enum PlaceHintsSettings {
  static let hintsKey = "places.hints.enabled"
  static let mapKey = "places.map.enabled"
  /// When each mark last announced itself, in seconds since 1970 by mark id. No coordinates.
  static let lastNoticeKey = "places.hints.lastNotified"

  static func hintsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: hintsKey)
  }

  static func mapEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: mapKey)
  }

  static func setHints(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: hintsKey)
  }

  static func setMap(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: mapKey)
  }

  static func lastNotified(_ defaults: UserDefaults = .standard) -> [UUID: Date] {
    let stored = defaults.dictionary(forKey: lastNoticeKey) as? [String: Double] ?? [:]
    var result: [UUID: Date] = [:]
    for (key, seconds) in stored {
      if let id = UUID(uuidString: key) { result[id] = Date(timeIntervalSince1970: seconds) }
    }
    return result
  }

  static func remember(_ id: UUID, at date: Date, _ defaults: UserDefaults = .standard) {
    var stored = defaults.dictionary(forKey: lastNoticeKey) as? [String: Double] ?? [:]
    stored[id.uuidString] = date.timeIntervalSince1970
    defaults.set(stored, forKey: lastNoticeKey)
  }
}

/// What happens when the phone says the owner came near a mark: the advice, or nothing.
enum PlaceHintDecision {
  /// The advice to announce for the mark `markId`, or `nil` when hints are off, the mark is
  /// gone or switched off, it was announced within the pause, or nothing is worth saying
  /// (`PlaceAdvisor`). Hidden accounts are never named.
  static func advice(
    forMark markId: UUID, marks: [PlaceMark], ledger: Ledger, today: DateOnly,
    enabled: Bool, lastNotified: [UUID: Date], now: Date
  ) -> PlaceAdvice? {
    guard enabled, let mark = marks.first(where: { $0.id == markId }), mark.enabled,
      PlaceGeofencing.shouldNotify(markId, lastNotified: lastNotified, now: now)
    else { return nil }
    let hidden = Set(ledger.dataset.paymentMethods.filter(\.hidden).map(\.id))
    return PlaceAdvisor.advice(for: mark, ledger: ledger, today: today, hidden: hidden)
  }
}

/// The words of the notice «Здесь лучше платить …». A notice shows on the lock screen, so it
/// names the card and the percent and nothing about sums.
enum PlaceHintText {
  static let table = "Places"
  static let keys = [
    "places.notice.body", "places.notice.bodyNoCategory", "places.notice.someCard",
    "places.notice.usual",
  ]

  @MainActor
  static func body(
    _ advice: PlaceAdvice, ledger: Ledger, _ environment: AppEnvironment
  ) -> String {
    let dataset = ledger.dataset
    var card = environment.language("places.notice.someCard", table: table)
    switch advice.best.holder {
    case .card(let id):
      if let name = dataset.cards.first(where: { $0.id == id })?.name { card = name }
    case .account(let id):
      if let name = dataset.paymentMethods.first(where: { $0.id == id })?.name { card = name }
    }
    let percent = environment.money.percent(advice.bestPercent)
    let category = advice.categoryId.flatMap { ledger.tree.category($0)?.name }
    var text: String
    if let category {
      text = String(
        format: environment.language("places.notice.body", table: table),
        locale: environment.language.locale, card, percent, category)
    } else {
      text = String(
        format: environment.language("places.notice.bodyNoCategory", table: table),
        locale: environment.language.locale, card, percent)
    }
    if advice.isUsualCard {
      text += " " + environment.language("places.notice.usual", table: table)
    }
    return text
  }
}
