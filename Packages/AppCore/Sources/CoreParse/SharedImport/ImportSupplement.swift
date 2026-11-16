import CoreKit
import Foundation

/// «Дополнить»: what a recognised purchase adds to an operation the owner already wrote. Only
/// fields the owner left empty are filled — the note, the time, the merchant code; the kind, the
/// sum, the currency, the account, the parts and their categories are the owner's and are never
/// touched, so a split operation keeps its parts as they are.
public enum ImportSupplement {
  public enum Field: String, CaseIterable, Hashable, Sendable {
    case note, time, mcc
  }

  /// The operation with the empty fields filled from `item`, and which were.
  ///
  /// The time is filled only for an operation with no time of its own
  /// (`ScreenshotMatch.hasOwnTime`) and only on the operation's own day: the picture's clock is
  /// read in the zone the operation was recorded in, and an operation is never moved to another
  /// day. A purchase at exactly 12:00 lands on the noon an operation without a time has, and
  /// reads as no time as before.
  public static func fill(
    _ entry: TransactionEntry, with item: RecognizedPurchase, calendar: CalendarContext
  ) -> (entry: TransactionEntry, filled: Set<Field>) {
    var result = entry
    var filled = Set<Field>()
    let transaction = entry.transaction

    let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let merchant = item.merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if note.isEmpty, !merchant.isEmpty {
      result.transaction.note = merchant
      filled.insert(.note)
    }

    if let time = item.time,
      !ScreenshotMatch.hasOwnTime(
        transaction.occurredAt, recordedIn: transaction.timeZoneId, calendar: calendar)
    {
      let zone = CalendarContext(timeZone: calendar.zone(recordedIn: transaction.timeZoneId))
      let day = zone.day(of: transaction.occurredAt)
      let moment = zone.moment(day, hour: time.hour, minute: time.minute)
      if day == item.day, moment != transaction.occurredAt {
        result.transaction.occurredAt = moment
        filled.insert(.time)
      }
    }

    if transaction.mcc == nil, let code = MerchantCode.normalized(item.mcc) {
      result.transaction.mcc = code
      filled.insert(.mcc)
    }
    return (result, filled)
  }
}
