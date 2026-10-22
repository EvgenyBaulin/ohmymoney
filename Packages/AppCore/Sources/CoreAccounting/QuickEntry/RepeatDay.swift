import CoreKit
import Foundation

/// One operation offered again, ticked: «кофе 250 ✓».
public struct RepeatProposal: Hashable, Sendable, Identifiable {
  /// The operation it repeats.
  public var id: UUID
  public var draft: TransactionDraft
  public var isSelected: Bool
}

/// «Повторить вчера» what the owner wrote by hand on a day, offered as
/// a list to tick before it is written again — the sheet opens, nothing is written until
/// «Записать».
public enum RepeatDay {
  /// An expense the owner typed: not deleted, not one the planning, a reconciliation, a
  /// transfer, an interest or a distribution of income wrote, not an import, not a payment on
  /// a debt or a purchase on credit (writing those twice would double a debt), not a
  /// contribution to a goal (the goal's own screen writes those).
  public static func isRepeatable(_ entry: TransactionEntry) -> Bool {
    let transaction = entry.transaction
    guard transaction.kind == .expense, !transaction.isDeleted, transaction.importBatchId == nil,
      transaction.debtId == nil, transaction.creditDebtId == nil,
      !entry.parts.contains(where: { $0.goalId != nil || $0.categorySource == .system })
    else { return false }
    // Every operation the application writes itself carries a key in `external_id` («sched:»,
    // «reconcile:», «transfer:», «ccinterest:»…); one typed by hand has none.
    if let key = transaction.externalId, !key.isEmpty { return false }
    return true
  }

  /// The operations of `sourceDay`, each as a draft for `targetDay` at the same time of day
  /// (the clock of the zone it was recorded in). The rate, the amount the account moved and the
  /// expected cashback are left out: they belong to the day of the purchase, and the app finds
  /// them again for the new one. Oldest first.
  public static func proposals(
    from entries: [TransactionEntry], on sourceDay: DateOnly, to targetDay: DateOnly,
    calendar: CalendarContext
  ) -> [RepeatProposal] {
    entries
      .filter { entry in
        isRepeatable(entry)
          && calendar.day(
            of: entry.transaction.occurredAt, recordedIn: entry.transaction.timeZoneId)
            == sourceDay
      }
      .sorted { $0.transaction.occurredAt < $1.transaction.occurredAt }
      .map { entry in
        RepeatProposal(
          id: entry.id, draft: draft(of: entry, on: targetDay, calendar: calendar), isSelected: true
        )
      }
  }

  static func draft(
    of entry: TransactionEntry, on day: DateOnly, calendar: CalendarContext
  ) -> TransactionDraft {
    let transaction = entry.transaction
    let clock = calendar.timeOfDay(transaction.occurredAt, recordedIn: transaction.timeZoneId)
    let zone = CalendarContext(timeZone: calendar.zone(recordedIn: transaction.timeZoneId))
    return TransactionDraft(
      kind: transaction.kind,
      occurredAt: zone.moment(day, hour: clock.hour, minute: clock.minute),
      currency: transaction.currency,
      amount: transaction.amountE4,
      amountExpression: transaction.amountExpr,
      note: transaction.note,
      placeId: transaction.placeId,
      paymentMethodId: transaction.paymentMethodId,
      parts: entry.parts.map { part in
        PartDraft(
          categoryId: part.categoryId, categorySource: part.categorySource,
          quality: part.quality, qualitySource: part.qualitySource, amount: part.amountE4,
          forWhom: part.forWhom, forPersonId: part.forPersonId, reimbursable: part.reimbursable,
          debtorPersonId: part.debtorPersonId,
          reimbursementStatus: part.reimbursable ? .expected : nil, eventId: part.eventId,
          note: part.note)
      },
      cardId: transaction.cardId)
  }
}
