import CoreKit
import Foundation

/// «Я в поездке»: what the sheet that switches the mode on offers and how a trip typed into it
/// becomes an event. The list holds the trips that are not over (a trip whose last day has gone
/// would switch itself off at once); «Новая поездка…» makes an event of kind «Поездка» with its
/// trip currency and its budget currency and the mode goes on for it.
public enum TripStart {
  /// The trips the mode can be switched on for: live events of kind «Поездка» whose last day is
  /// not before `today`, the soonest first.
  public static func choices(events: [Event], today: DateOnly) -> [Event] {
    events.filter { $0.kind == .trip && !$0.archived && $0.endDate >= today }
      .sorted { left, right in
        left.startDate != right.startDate
          ? left.startDate < right.startDate
          : NameKey.fold(left.name) < NameKey.fold(right.name)
      }
  }

  /// A trip being typed: the name is the country or the place.
  public struct Draft: Hashable, Sendable {
    public var name: String
    public var startDate: DateOnly
    public var endDate: DateOnly
    /// The one currency of the trip; `nil` — the entry keeps its own.
    public var tripCurrency: CurrencyCode?
    /// The budget; `nil` or zero — none.
    public var budget: AmountE4?
    /// The currency the budget is kept in.
    public var budgetCurrency: CurrencyCode

    public init(
      name: String, startDate: DateOnly, endDate: DateOnly, tripCurrency: CurrencyCode? = nil,
      budget: AmountE4? = nil, budgetCurrency: CurrencyCode = .rub
    ) {
      self.name = name
      self.startDate = startDate
      self.endDate = endDate
      self.tripCurrency = tripCurrency
      self.budget = budget
      self.budgetCurrency = budgetCurrency
    }
  }

  public enum Issue: String, Hashable, Sendable {
    case emptyName
    case endsBeforeItStarts
    case alreadyOver
    case negativeBudget
  }

  /// Why the draft cannot be started, or `nil`. A trip is not started in the past: its mode would
  /// end the moment it began.
  public static func issue(of draft: Draft, today: DateOnly) -> Issue? {
    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
    if draft.endDate < draft.startDate { return .endsBeforeItStarts }
    if draft.endDate < today { return .alreadyOver }
    if let budget = draft.budget, budget.raw < 0 { return .negativeBudget }
    return nil
  }

  /// The event of the draft: kind «Поездка», the name without spaces around it, no budget when
  /// the figure is empty or zero. `nil` when the draft has an issue.
  public static func event(from draft: Draft, today: DateOnly, id: UUID = UUID()) -> Event? {
    guard issue(of: draft, today: today) == nil else { return nil }
    let budget = draft.budget.flatMap { $0.raw > 0 ? $0 : nil }
    return Event(
      id: id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), kind: .trip,
      startDate: draft.startDate, endDate: draft.endDate, budgetE4: budget,
      tripCurrency: draft.tripCurrency, budgetCurrency: budget == nil ? nil : draft.budgetCurrency)
  }
}
