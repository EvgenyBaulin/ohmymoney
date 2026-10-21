import CoreKit
import Foundation

/// The trip mode as a state of the settings, the events and today: on for an event of kind
/// «Поездка» until its last day is over, then off by itself, with a card «С возвращением!» the
/// morning after, and a «Продлить» that moves the last day. The mode changes only the defaults of
/// the entry (the currency and the event of a new operation); the Overview and the reports stay in
/// the default currency as before.
public enum TripMode {
  public enum State: Hashable, Sendable {
    /// No trip is on.
    case off
    /// On: today is not after the last day of the trip.
    case on(Event)
    /// The settings still name a trip whose last day is over: the app turns the mode off
    /// (`afterDayChange`) and the card waits for the morning.
    case ended(Event)
  }

  /// The state the settings and the events give. A trip that is not found (deleted, archived
  /// or not of kind «Поездка») is no trip.
  public static func state(settings: TripSettings, events: [Event], today: DateOnly) -> State {
    guard let id = settings.activeEventId,
      let event = events.first(where: { $0.id == id && $0.kind == .trip && !$0.archived })
    else { return .off }
    return today > event.endDate ? .ended(event) : .on(event)
  }

  /// The settings after the day has changed: a trip whose last day is over turns the mode off and
  /// leaves its event for the card. Nothing else changes.
  public static func afterDayChange(
    settings: TripSettings, events: [Event], today: DateOnly
  ) -> TripSettings {
    var result = settings
    switch state(settings: settings, events: events, today: today) {
    case .ended(let event):
      result.activeEventId = nil
      result.returnCardEventId = event.id
    case .off:
      // The trip is gone: a mode that names nothing is cleared, and a card for nothing too.
      if settings.activeEventId != nil { result.activeEventId = nil }
    case .on:
      break
    }
    if let card = result.returnCardEventId,
      !events.contains(where: { $0.id == card && !$0.archived })
    {
      result.returnCardEventId = nil
    }
    return result
  }

  /// The trip the card «С возвращением!» is for: the one whose last day was before today. It
  /// shows from the morning after the last day until the owner closes it.
  public static func welcomeBack(
    settings: TripSettings, events: [Event], today: DateOnly
  ) -> Event? {
    guard let id = settings.returnCardEventId,
      let event = events.first(where: { $0.id == id && !$0.archived }), today > event.endDate
    else { return nil }
    return event
  }

  /// The settings with the mode on for `event`, whatever was on before; a card waiting for another
  /// trip stays.
  public static func switchingOn(_ event: Event, settings: TripSettings) -> TripSettings {
    var result = settings
    result.activeEventId = event.id
    if result.returnCardEventId == event.id { result.returnCardEventId = nil }
    return result
  }

  /// The settings with the mode off (the owner switched it off by hand).
  public static func switchingOff(settings: TripSettings) -> TripSettings {
    var result = settings
    result.activeEventId = nil
    return result
  }

  /// The card closed.
  public static func dismissingCard(settings: TripSettings) -> TripSettings {
    var result = settings
    result.returnCardEventId = nil
    return result
  }

  /// «Продлить»: the trip ends on `newEnd` instead — never before it started, and an end earlier
  /// than the present one is no extension. The mode comes back on, the card goes away.
  public static func extending(
    _ event: Event, to newEnd: DateOnly, settings: TripSettings
  ) -> (event: Event, settings: TripSettings)? {
    guard newEnd > event.endDate else { return nil }
    var extended = event
    extended.endDate = newEnd
    return (extended, switchingOn(extended, settings: settings))
  }

  /// The line of the toolbar: where the trip is, until when, in which currency and what budget.
  public struct Line: Hashable, Sendable {
    public var name: String
    public var endDate: DateOnly
    public var currency: CurrencyCode?
    /// The budget in the default currency.
    public var budget: AmountE4?

    public init(name: String, endDate: DateOnly, currency: CurrencyCode?, budget: AmountE4?) {
      self.name = name
      self.endDate = endDate
      self.currency = currency
      self.budget = budget
    }
  }

  public static func line(for event: Event, budget: AmountE4?) -> Line {
    Line(name: event.name, endDate: event.endDate, currency: event.tripCurrency, budget: budget)
  }

  /// What a new operation takes from the mode: the currency of the trip and the event. `nil` —
  /// the mode is off and the entry keeps its own defaults.
  public struct EntryDefaults: Hashable, Sendable {
    public var currency: CurrencyCode?
    public var eventId: UUID

    public init(currency: CurrencyCode?, eventId: UUID) {
      self.currency = currency
      self.eventId = eventId
    }
  }

  public static func entryDefaults(_ state: State) -> EntryDefaults? {
    guard case .on(let event) = state else { return nil }
    return EntryDefaults(currency: event.tripCurrency, eventId: event.id)
  }
}
