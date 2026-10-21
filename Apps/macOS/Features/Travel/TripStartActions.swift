import AppCore
import AppDatabase
import Foundation

/// The writes behind «Я в поездке»: the mode goes on for a trip that is there or for one just
/// made, and goes off by hand. The mode is a state of the Mac's day, not an edit of the books
/// (`TravelRepository`); a new trip is an event, written as any event is — one step of ⌘Z — and
/// only when that write succeeded does the mode go on for it. The strip reads the mode from the
/// next light refresh, and that is also what hands the entry its defaults.
@MainActor
struct TripStartActions {
  let environment: AppEnvironment
  let compute: ComputeStore
  private let planning: PlanningActions

  init(_ deps: AppDependencies) {
    environment = deps.environment
    compute = deps.compute
    planning = PlanningActions(deps)
  }

  private var repository: TravelRepository? {
    environment.stack.map { TravelRepository(writer: $0.writer) }
  }

  /// The mode on for a trip that is already an event.
  @discardableResult
  func switchOn(_ event: Event) -> Bool {
    guard let repository, let settings = try? repository.settings() else { return false }
    do {
      try repository.save(TripMode.switchingOn(event, settings: settings))
    } catch {
      return false
    }
    compute.refreshLight()
    return true
  }

  /// «Я вернулся»: the mode off, the trip stays as it is.
  @discardableResult
  func switchOff() -> Bool {
    guard let repository, let settings = try? repository.settings() else { return false }
    do {
      try repository.save(TripMode.switchingOff(settings: settings))
    } catch {
      return false
    }
    compute.refreshLight()
    return true
  }

  /// A new trip: the event first, then — when asked — the mode for it. A trip that has the name
  /// and the days of one in the archive brings that one back (`PlanningActions.save`), so the
  /// mode is switched on for the event as it was saved, found by id and else by name and days.
  @discardableResult
  func start(_ draft: TripStart.Draft, switchingOn: Bool) -> Bool {
    guard let event = TripStart.event(from: draft, today: environment.today),
      planning.save(event)
    else { return false }
    guard switchingOn else {
      compute.refreshLight()
      return true
    }
    let trips = (try? repository?.trips()) ?? []
    guard
      let saved = trips.first(where: { $0.id == event.id })
        ?? trips.first(where: {
          $0.startDate == event.startDate
            && $0.name.compare(event.name, options: [.caseInsensitive]) == .orderedSame
        })
    else { return false }
    return switchOn(saved)
  }
}

extension AppEnvironment {
  /// Rubles per unit of a currency on `day`, from the cache of the rates of the Bank of Russia
  /// (`nil` — the currency has none): for turning a fixed fee of a card into the currency it is
  /// charged in.
  func rubPerUnitReader(on day: DateOnly) -> (CurrencyCode) -> Decimal? {
    let table = (try? rates?.table()) ?? RateTable()
    return { table.resolve($0, on: day)?.rate.perUnit }
  }
}
