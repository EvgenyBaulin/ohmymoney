import CoreAnalytics
import CoreKit
import Foundation

/// What the plan of the year keeps in the database, read with the data: the limits that differ
/// in one month, the articles of the budgets of events, the owner's templates of events, and the
/// buffer of the month (`settings`, `MonthBufferSettings`) with the operations marked as taken
/// from it.
public struct YearPlanData: Hashable, Sendable {
  public var monthExceptions: [LimitMonthException]
  public var eventItems: [EventBudgetItem]
  /// The owner's own templates; the ready ones are in `EventTemplates`.
  public var eventTemplates: [EventTemplate]
  public var buffer: MonthBufferSettings
  public var bufferMarks: Set<UUID>

  public init(
    monthExceptions: [LimitMonthException] = [], eventItems: [EventBudgetItem] = [],
    eventTemplates: [EventTemplate] = [], buffer: MonthBufferSettings = MonthBufferSettings(),
    bufferMarks: Set<UUID> = []
  ) {
    self.monthExceptions = monthExceptions
    self.eventItems = eventItems
    self.eventTemplates = eventTemplates
    self.buffer = buffer
    self.bufferMarks = bufferMarks
  }

  public static let empty = YearPlanData()

  /// The articles of one event, in the owner's order.
  public func items(of event: UUID) -> [EventBudgetItem] {
    eventItems.filter { $0.eventId == event }.sorted {
      ($0.sort, $0.id.uuidString) < ($1.sort, $1.id.uuidString)
    }
  }
}

extension Dataset {
  public static let subscriptionsKey = "planning.subscriptions"
  public static let yearPlanKey = "planning.yearPlan"

  /// The extras of the subscriptions: terms, usage marks, people sharing, groups kept whole.
  public var subscriptions: SubscriptionBook {
    get { extras.value(Self.subscriptionsKey) ?? .empty }
    set { extras.set(newValue, for: Self.subscriptionsKey) }
  }

  /// The stored forms of the plan of the year.
  public var yearPlan: YearPlanData {
    get { extras.value(Self.yearPlanKey) ?? .empty }
    set { extras.set(newValue, for: Self.yearPlanKey) }
  }
}
