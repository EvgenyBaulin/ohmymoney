import CoreKit
import Foundation

/// «Что сделать сейчас»: the few things on the Overview that have a button to press. Only an
/// item with an action is here — a tip with nothing to press stays in the full «Стоит
/// посмотреть» list. The order is fixed: questions about closing partly paid payments, payments
/// overdue and due today (the oldest first), expected incomes that did not come, then things to
/// sort out («Разобрать») and statements to load («Загрузить»); at most three are shown.
public struct DoNowItem: Hashable, Sendable, Identifiable {
  /// What the button does.
  public enum Action: String, Hashable, Sendable {
    /// «Провести»: record the payment of a due date.
    case post
    /// Ask whether to close a due date whose parts are within 10 % of its price.
    case closeRemainder
    /// «Не пришёл?»: an expected income whose day has passed without the money — enter the
    /// day it came, close it or move it.
    case income
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
  /// The expected income of a «Не пришёл?» item; `day` is its due date.
  public var incomeId: UUID?
  /// The day the recurrence of that income puts the due on (`day` unless it was moved): the
  /// key «Закрыть» and «Перенести» of a recurring income answer for.
  public var scheduled: DateOnly?
  /// The income is recurring: its answers are for this due alone, and «Это ошибка» edits the
  /// recurrence.
  public var recurring: Bool
  /// The account a «Загрузить» item is about.
  public var accountId: UUID?
  /// How many days ago the last statement of that account was loaded.
  public var daysAgo: Int

  public init(
    id: String, action: Action, paymentId: UUID? = nil, day: DateOnly? = nil, count: Int = 1,
    accountId: UUID? = nil, daysAgo: Int = 0, incomeId: UUID? = nil, scheduled: DateOnly? = nil,
    recurring: Bool = false
  ) {
    self.incomeId = incomeId
    self.scheduled = scheduled
    self.recurring = recurring
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
    payments: [ScheduledPayment], overdueIncomes: [OverdueIncomeItem] = [],
    partQuestions: [DoNowItem] = [], reviews: [DoNowSource] = [],
    statements: [DoNowSource] = [], today: DateOnly
  ) -> DoNowList {
    let questions = partQuestions.filter { $0.action == .closeRemainder }
      .sorted { ($0.day ?? today, $0.id) < ($1.day ?? today, $1.id) }
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
    // One item per expectation — its oldest due date. A recurring one asks about that due
    // alone: its answers skip or move it, and the recurrence stays.
    var asked = Set<UUID>()
    let incomes = overdueIncomes.filter { $0.due < today }
      .sorted { ($0.due, $0.incomeId.uuidString) < ($1.due, $1.incomeId.uuidString) }
      .compactMap { item -> DoNowItem? in
        guard asked.insert(item.incomeId).inserted else { return nil }
        return DoNowItem(
          id: "income:\(item.incomeId.uuidString):\(item.scheduled.iso)", action: .income,
          day: item.due, incomeId: item.incomeId, scheduled: item.scheduled,
          recurring: !item.isOneOff)
      }
    let all = questions + due + incomes + items(reviews, .review) + items(statements, .load)
    return DoNowList(items: Array(all.prefix(limit)), more: max(0, all.count - limit))
  }
}
