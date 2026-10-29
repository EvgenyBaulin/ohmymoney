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

  public init(
    id: UUID, kind: TransactionKind, occurredAt: Date, timeZoneId: String? = nil,
    currency: CurrencyCode = .rub, amountE4: AmountE4
  ) {
    self.id = id
    self.kind = kind
    self.occurredAt = occurredAt
    self.timeZoneId = timeZoneId
    self.currency = currency
    self.amountE4 = amountE4
  }
}

/// What to offer for a scanned receipt.
public enum ReceiptProposal: Hashable, Sendable {
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
}

public enum ReceiptMatch {
  /// Looks for an operation of the receipt's kind with the same sum in roubles, whose own
  /// day (in the zone it was recorded in) is the day of the receipt, the day before or the
  /// day after. The nearest to the receipt's moment comes first: the same day before the
  /// neighbouring ones, then by the distance in time. Nothing goes to the network.
  public static func propose(
    _ receipt: ReceiptQR, among candidates: [ReceiptCandidate], calendar: CalendarContext
  ) -> ReceiptProposal {
    let moment = receipt.moment(in: calendar)
    let kind = receipt.operation.transactionKind
    let fitting = candidates
      .filter { $0.kind == kind && $0.currency == .rub && $0.amountE4 == receipt.amountE4 }
      .compactMap { candidate -> (candidate: ReceiptCandidate, apart: Int, distance: TimeInterval)? in
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
    return .new(draft(for: receipt, calendar: calendar))
  }

  /// A new operation with the sum, the day and the time of the receipt, on the clock of `calendar`.
  public static func draft(for receipt: ReceiptQR, calendar: CalendarContext) -> ReceiptDraft {
    ReceiptDraft(
      kind: receipt.operation.transactionKind, currency: .rub, amountE4: receipt.amountE4,
      moment: receipt.moment(in: calendar), day: receipt.day, time: receipt.time)
  }

  private static func daysBetween(_ from: DateOnly, _ to: DateOnly, _ calendar: CalendarContext)
    -> Int
  {
    let start = calendar.startOfDay(from)
    let end = calendar.startOfDay(to)
    // Rounded: a day with the clocks moved is 23 or 25 hours long.
    return Int((end.timeIntervalSince(start) / 86_400).rounded())
  }
}
