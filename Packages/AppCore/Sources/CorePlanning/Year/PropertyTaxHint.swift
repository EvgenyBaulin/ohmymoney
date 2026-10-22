import CoreAnalytics
import CoreKit
import Foundation

/// One expense of «Налоги и сборы» of the last year, as the hint reads it. The caller leaves
/// out what is not property tax by nature: the tax of a self-employed person (`npd:` and
/// `tax:` operations) and anything under the system subcategories of that tax.
public struct TaxRecord: Hashable, Sendable {
  public var day: DateOnly
  public var amount: AmountE4
  public var categoryId: UUID?
  public var title: String

  public init(day: DateOnly, amount: AmountE4, categoryId: UUID? = nil, title: String = "") {
    self.day = day
    self.amount = amount
    self.categoryId = categoryId
    self.title = title
  }
}

/// «В прошлом году был налог 8 000 ₽ — запланировать?» — a line of «Стоит посмотреть» in
/// November, for whoever paid a tax in the autumn of the year before.
public struct PropertyTaxHint: Hashable, Sendable, Identifiable {
  public var title: String
  public var categoryId: UUID?
  /// What was paid in the autumn of the last year under this name.
  public var lastAmount: AmountE4
  /// The day of the last payment.
  public var lastDate: DateOnly
  /// 1 December of this year, never moved to a working day: paying earlier is always fine.
  public var due: DateOnly
  /// Two weeks before the due date.
  public var remindOn: DateOnly

  public var id: String {
    "propertyTax:\(due.year):\(categoryId?.uuidString ?? NameKey.fold(title))"
  }

  /// The scheduled payment «Запланировать» makes: yearly, on 1 December, reminding two weeks
  /// before, for last year's amount.
  public func scheduledPayment(
    paymentMethodId: UUID? = nil, id: UUID = UUID()
  ) -> ScheduledPayment {
    ScheduledPayment(
      id: id, name: title, kind: .bill, amountE4: lastAmount, currency: .rub,
      categoryId: categoryId, paymentMethodId: paymentMethodId, freq: .yearly, interval: 1,
      day: due.day, month: due.month, nextDate: due, remindDaysBefore: Self.remindDays)
  }

  public static let remindDays = 14
}

public enum PropertyTaxHints {
  /// The payments of the last year count from this day of the year...
  public static let firstMonthOfAutumn = 9
  /// ...and the hint lives from 1 November to the due date.
  public static let hintMonth = 11
  public static let dueMonth = 12
  public static let dueDay = 1

  /// The hints for `today`: one per category (or, without one, per name) of the autumn tax
  /// payments of the last year, when it is November or 1 December and nothing is planned for it
  /// yet (`planned`: the owner's scheduled payments; a payment counts when it has the same
  /// category or the same name and is due between 1 October and the end of the year, or repeats
  /// yearly in December). Dismissed hints (`dismissed`, `PropertyTaxHint.id`) stay away.
  public static func hints(
    records: [TaxRecord], today: DateOnly, planned: [ScheduledPayment] = [],
    dismissed: Set<String> = []
  ) -> [PropertyTaxHint] {
    let due = DateOnly(year: today.year, month: dueMonth, day: dueDay)
    guard today >= DateOnly(year: today.year, month: hintMonth, day: 1), today <= due else {
      return []
    }
    let lastYear = today.year - 1
    let autumn = records.filter {
      $0.day.year == lastYear && $0.day.month >= firstMonthOfAutumn && $0.amount.raw > 0
    }
    var groups: [String: [TaxRecord]] = [:]
    for record in autumn {
      let key = record.categoryId.map { "c:\($0.uuidString)" } ?? "n:\(NameKey.fold(record.title))"
      groups[key, default: []].append(record)
    }
    var result: [PropertyTaxHint] = []
    for group in groups.values {
      guard let biggest = group.max(by: { ($0.amount, $0.day) < ($1.amount, $1.day) }),
        let latest = group.map(\.day).max()
      else { continue }
      let hint = PropertyTaxHint(
        title: biggest.title, categoryId: biggest.categoryId,
        lastAmount: AmountE4.sum(group.map(\.amount)), lastDate: latest, due: due,
        remindOn: due.adding(days: -PropertyTaxHint.remindDays))
      guard !dismissed.contains(hint.id), !isPlanned(hint, in: planned) else { continue }
      result.append(hint)
    }
    return result.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
  }

  private static func isPlanned(_ hint: PropertyTaxHint, in payments: [ScheduledPayment]) -> Bool {
    let from = DateOnly(year: hint.due.year, month: 10, day: 1)
    let to = DateOnly(year: hint.due.year, month: 12, day: 31)
    return payments.contains { payment in
      guard payment.active else { return false }
      let alike =
        (hint.categoryId != nil && payment.categoryId == hint.categoryId)
        || NameKey.fold(payment.name) == NameKey.fold(hint.title)
      guard alike else { return false }
      if let next = payment.nextDate, next >= from, next <= to { return true }
      return payment.freq == .yearly && payment.month == hint.due.month
    }
  }
}
