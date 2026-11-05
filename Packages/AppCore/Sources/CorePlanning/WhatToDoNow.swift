import CoreKit
import Foundation

/// «Что сделать сейчас»: the few things on the Overview that have a button to press. Only an
/// item with an action is here — a tip with nothing to press stays in the full «Стоит
/// посмотреть» list. The order is fixed: payments overdue and due today first (the oldest
/// first), then things to sort out («Разобрать»), then statements to load («Загрузить»); at most
/// three are shown, and with nothing to do the list is empty and the block is not drawn.
public struct DoNowItem: Hashable, Sendable, Identifiable {
  /// What the button does.
  public enum Action: String, Hashable, Sendable {
    /// «Провести»: record the payment of a due date.
    case post
    /// «Разобрать»: sort out what waits for a decision.
    case review
    /// «Загрузить»: load a bank statement.
    case load
  }

  public var id: String
  public var action: Action
  /// The payment of a «Провести» item.
  public var paymentId: UUID?
  /// Its due date; before today it is overdue.
  public var day: DateOnly?
  /// How many things wait behind a «Разобрать» item.
  public var count: Int
  /// The account a «Загрузить» item is about.
  public var accountId: UUID?
  /// How many days ago the last statement of that account was loaded.
  public var daysAgo: Int

  public init(
    id: String, action: Action, paymentId: UUID? = nil, day: DateOnly? = nil, count: Int = 1,
    accountId: UUID? = nil, daysAgo: Int = 0
  ) {
    self.id = id
    self.action = action
    self.paymentId = paymentId
    self.day = day
    self.count = count
    self.accountId = accountId
    self.daysAgo = daysAgo
  }

  /// A payment whose day has passed.
  public func isOverdue(today: DateOnly) -> Bool {
    guard action == .post, let day else { return false }
    return day < today
  }
}

/// A source of «Разобрать» or «Загрузить» the screen found: a stable id and how many things wait.
/// A source with nothing waiting is no item.
public struct DoNowSource: Hashable, Sendable {
  public var id: String
  public var count: Int
  public var accountId: UUID?
  public var daysAgo: Int

  public init(id: String, count: Int, accountId: UUID? = nil, daysAgo: Int = 0) {
    self.id = id
    self.count = count
    self.accountId = accountId
    self.daysAgo = daysAgo
  }
}

public struct DoNowList: Hashable, Sendable {
  /// At most `WhatToDoNow.limit`, in the order above.
  public var items: [DoNowItem]
  /// Items that did not fit; «Все» opens the full list.
  public var more: Int

  public var isEmpty: Bool { items.isEmpty }
}

public enum WhatToDoNow {
  public static let limit = 3

  public static func list(
    payments: [ScheduledPayment], reviews: [DoNowSource] = [], statements: [DoNowSource] = [],
    today: DateOnly
  ) -> DoNowList {
    let due = payments.compactMap { payment -> DoNowItem? in
      guard payment.active, let day = payment.nextDate, day <= today else { return nil }
      return DoNowItem(
        id: "post:\(payment.id.uuidString):\(day.iso)", action: .post, paymentId: payment.id,
        day: day)
    }
    // Oldest first; two on the same day keep one fixed order.
    .sorted { ($0.day ?? today, $0.id) < ($1.day ?? today, $1.id) }
    func items(_ sources: [DoNowSource], _ action: DoNowItem.Action) -> [DoNowItem] {
      sources.filter { $0.count > 0 }.sorted { $0.id < $1.id }.map {
        DoNowItem(
          id: "\(action.rawValue):\($0.id)", action: action, count: $0.count,
          accountId: $0.accountId, daysAgo: $0.daysAgo)
      }
    }
    let all = due + items(reviews, .review) + items(statements, .load)
    return DoNowList(items: Array(all.prefix(limit)), more: max(0, all.count - limit))
  }
}
