import CoreKit
import Foundation

/// An operation of the books as the matching of a receipt sees it.
public struct ReceiptCandidate: Hashable, Sendable {
  public var id: UUID
  public var kind: TransactionKind
  public var occurredAt: Date
  /// The zone the operation was recorded in (`nil`: the books' own).
  public var timeZoneId: String?
  public var currency: CurrencyCode
  public var amountE4: AmountE4
  /// The numbers of the receipt the operation already holds; `nil`: none.
  public var receipt: ReceiptNumbers?

  public init(
    id: UUID, kind: TransactionKind, occurredAt: Date, timeZoneId: String? = nil,
    currency: CurrencyCode = .rub, amountE4: AmountE4, receipt: ReceiptNumbers? = nil
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.timeZoneId = timeZoneId
    self.currency = currency
    self.amountE4 = amountE4
    self.receipt = receipt
  }
}

/// What to offer for a scanned receipt.
public enum ReceiptProposal: Hashable, Sendable {
  /// The same receipt is already on an operation: nothing is written, the operation is shown.
  case alreadyRecorded(ReceiptCandidate)
  /// An operation of the same sum a day either way: add the time of the receipt (and a photo).
  /// `moment` is on the clock of the zone the operation was recorded in.
  /// `others` are further operations that fit, nearest first.
  case supplement(ReceiptCandidate, moment: Date, others: [ReceiptCandidate])
  /// Nothing fits: a new operation with the sum, the day and the time of the receipt.
  case new(ReceiptDraft)
}

/// The fields of a new operation read from a receipt.
public struct ReceiptDraft: Hashable, Sendable {
  public var kind: TransactionKind
  public var currency: CurrencyCode
  public var amountE4: AmountE4
  public var moment: Date
  public var day: DateOnly
  public var time: TimeOfDay
  /// Operations of the same kind that are close without being the same: the sum differs by a
  /// rounding or a tip and the moment is within a day (`ReceiptMatch.similar`). Offered
  /// to choose from, never taken for the receipt's own.
  public var similar: [ReceiptCandidate] = []
}

public enum ReceiptMatch {
  /// Looks for an operation of the receipt's kind with the same sum in roubles, whose own
  /// day (in the zone it was recorded in) is the day of the receipt, the day before or the
  /// day after. The nearest to the receipt's moment comes first: the same day before the
  /// neighbouring ones, then by the distance in time. Nothing goes to the network.
  ///
  /// An operation that already holds this very receipt (`recorded`) comes before everything:
  /// the receipt is not recorded twice and gives no time to another operation. An operation
  /// that holds another receipt is another purchase and is never offered.
  public static func propose(
    _ receipt: ReceiptQR, among all: [ReceiptCandidate], calendar: CalendarContext
  ) -> ReceiptProposal {
    if let holder = recorded(receipt, among: all) { return .alreadyRecorded(holder) }
    let candidates = all.filter { $0.receipt == nil }
    let moment = receipt.moment(in: calendar)
    let kind = receipt.operation.transactionKind
    let fitting =
      candidates
      .filter { $0.kind == kind && $0.currency == .rub && $0.amountE4 == receipt.amountE4 }
      .compactMap {
        candidate -> (candidate: ReceiptCandidate, apart: Int, distance: TimeInterval)? in
        let day = calendar.day(of: candidate.occurredAt, recordedIn: candidate.timeZoneId)
        let apart = abs(daysBetween(day, receipt.day, calendar))
        guard apart <= 1 else { return nil }
        return (candidate, apart, abs(candidate.occurredAt.timeIntervalSince(moment)))
      }
      .sorted {
        if $0.apart != $1.apart { return $0.apart < $1.apart }
        if $0.distance != $1.distance { return $0.distance < $1.distance }
        return $0.candidate.id.uuidString < $1.candidate.id.uuidString
      }
      .map(\.candidate)
    if let first = fitting.first {
      // The receipt's clock is the shop's: it is read in the zone the operation was recorded in.
      let zone = CalendarContext(timeZone: calendar.zone(recordedIn: first.timeZoneId))
      return .supplement(
        first, moment: receipt.moment(in: zone), others: Array(fitting.dropFirst()))
    }
    var draft = draft(for: receipt, calendar: calendar)
    draft.similar = similar(to: receipt, among: candidates, calendar: calendar)
    return .new(draft)
  }

  /// The operation that already holds the receipt: the same drive and document number (as
  /// numbers) and no other fiscal sign. A receipt without a key is never recorded; of several
  /// holders — two devices that read it apart — the earliest recorded comes first.
  public static func recorded(
    _ receipt: ReceiptQR, among candidates: [ReceiptCandidate]
  ) -> ReceiptCandidate? {
    guard let numbers = receipt.numbers else { return nil }
    return
      candidates
      .filter { $0.receipt.map { $0.isSameReceipt(as: numbers) } ?? false }
      .min {
        if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  /// The largest difference of sums that still looks like the same purchase: 5 % of the receipt.
  static func tolerance(of receipt: AmountE4) -> Int64 {
    receipt.raw / 20
  }

  /// The longest distance between the moment of the receipt and the operation's.
  static let window: TimeInterval = 24 * 3_600

  /// Operations of the receipt's kind in roubles whose sum is within `tolerance` of the receipt
  /// (but not the same) and whose moment is within `window` of the receipt's; the nearest sum
  /// first, then the nearest moment. A suggestion only: the owner picks it.
  public static func similar(
    to receipt: ReceiptQR, among candidates: [ReceiptCandidate], calendar: CalendarContext
  ) -> [ReceiptCandidate] {
    let moment = receipt.moment(in: calendar)
    let kind = receipt.operation.transactionKind
    let allowed = tolerance(of: receipt.amountE4)
    return
      candidates
      .filter { $0.kind == kind && $0.currency == .rub && $0.receipt == nil }
      .compactMap { candidate -> (ReceiptCandidate, Int64, TimeInterval)? in
        let apart = abs(candidate.amountE4.raw - receipt.amountE4.raw)
        let distance = abs(candidate.occurredAt.timeIntervalSince(moment))
        guard apart != 0, apart <= allowed, distance <= window else { return nil }
        return (candidate, apart, distance)
      }
      .sorted {
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        if $0.2 != $1.2 { return $0.2 < $1.2 }
        return $0.0.id.uuidString < $1.0.id.uuidString
      }
      .map(\.0)
  }

  /// A new operation with the sum, the day and the time of the receipt, on the clock of `calendar`.
  public static func draft(for receipt: ReceiptQR, calendar: CalendarContext) -> ReceiptDraft {
    ReceiptDraft(
      kind: receipt.operation.transactionKind, currency: .rub, amountE4: receipt.amountE4,
      moment: receipt.moment(in: calendar), day: receipt.day, time: receipt.time)
  }

  private static func daysBetween(
    _ from: DateOnly, _ to: DateOnly, _ calendar: CalendarContext
  )
    -> Int
  {
    let start = calendar.startOfDay(from)
    let end = calendar.startOfDay(to)
    // Rounded: a day with the clocks moved is 23 or 25 hours long.
    return Int((end.timeIntervalSince(start) / 86_400).rounded())
  }
}
