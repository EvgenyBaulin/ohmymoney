import CoreKit
import Foundation

/// One operation or one side of a transfer on the account selected for a screenshot.
public struct ScreenshotCandidate: Hashable, Sendable, Identifiable {
  public var id: UUID
  public var accountID: UUID
  public var kind: TransactionKind
  public var currency: CurrencyCode
  public var amount: AmountE4
  public var occurredAt: Date
  public var timeZoneID: String?
  public var isTransfer: Bool

  public init(
    id: UUID, accountID: UUID, kind: TransactionKind, currency: CurrencyCode,
    amount: AmountE4, occurredAt: Date, timeZoneID: String? = nil, isTransfer: Bool = false
  ) {
    self.id = id
    self.accountID = accountID
    self.kind = kind
    self.currency = currency
    self.amount = amount
    self.occurredAt = occurredAt
    self.timeZoneID = timeZoneID
    self.isTransfer = isTransfer
  }
}

public struct ScreenshotProposal: Hashable, Sendable {
  public var matches: [ScreenshotCandidate]
  public var isSimilar: Bool
}

public enum ScreenshotMatch {
  public static func candidates(
    entries: [TransactionEntry], transfers: [Transfer]
  )
    -> [ScreenshotCandidate]
  {
    var result = entries.compactMap { entry -> ScreenshotCandidate? in
      let transaction = entry.transaction
      guard !transaction.isDeleted, let account = transaction.paymentMethodId else { return nil }
      return ScreenshotCandidate(
        id: transaction.id, accountID: account, kind: transaction.kind,
        currency: transaction.currency, amount: transaction.amountE4,
        occurredAt: transaction.occurredAt, timeZoneID: transaction.timeZoneId)
    }
    for transfer in transfers {
      result.append(
        ScreenshotCandidate(
          id: transfer.id, accountID: transfer.fromAccountId,
          kind: .expense, currency: transfer.fromCurrency, amount: transfer.fromAmountE4,
          occurredAt: transfer.occurredAt, isTransfer: true))
      result.append(
        ScreenshotCandidate(
          id: transfer.id, accountID: transfer.toAccountId,
          kind: .income, currency: transfer.toCurrency, amount: transfer.toAmountE4,
          occurredAt: transfer.arrivedAt ?? transfer.occurredAt, isTransfer: true))
    }
    return result
  }

  /// Exact amount, account and recorded day first. Only without an exact match are the
  /// receipt's tolerances used: up to 5 % of the screenshot's amount and 24 hours either way.
  /// Every result is a proposal for the owner to choose, never an automatic merge.
  public static func propose(
    amount: AmountE4, kind: TransactionKind, currency: CurrencyCode,
    accountID: UUID, day: DateOnly, time: TimeOfDay?, among candidates: [ScreenshotCandidate],
    calendar: CalendarContext
  ) -> ScreenshotProposal {
    guard amount.raw > 0 else { return ScreenshotProposal(matches: [], isSimilar: false) }
    let eligible = candidates.filter {
      $0.accountID == accountID && $0.kind == kind && $0.currency == currency && $0.amount.raw > 0
    }
    func moment(_ candidate: ScreenshotCandidate) -> Date {
      let zone = CalendarContext(timeZone: calendar.zone(recordedIn: candidate.timeZoneID))
      return zone.moment(day, hour: time?.hour ?? 12, minute: time?.minute ?? 0)
    }
    func distance(_ candidate: ScreenshotCandidate) -> TimeInterval {
      abs(candidate.occurredAt.timeIntervalSince(moment(candidate)))
    }
    let exact = eligible.filter {
      $0.amount == amount && calendar.day(of: $0.occurredAt, recordedIn: $0.timeZoneID) == day
    }.sorted {
      if distance($0) != distance($1) { return distance($0) < distance($1) }
      return $0.id.uuidString < $1.id.uuidString
    }
    if !exact.isEmpty { return ScreenshotProposal(matches: exact, isSimilar: false) }
    // A date alone cannot establish a 24-hour distance. The screen asks for the clock
    // before offering approximate matches, rather than inventing a moment for the screenshot.
    guard time != nil else { return ScreenshotProposal(matches: [], isSimilar: false) }
    let similar = eligible.filter {
      abs($0.amount.raw - amount.raw) <= ReceiptMatch.tolerance(of: amount)
        && distance($0) <= ReceiptMatch.window
    }.sorted {
      let left = abs($0.amount.raw - amount.raw)
      let right = abs($1.amount.raw - amount.raw)
      if left != right { return left < right }
      if distance($0) != distance($1) { return distance($0) < distance($1) }
      return $0.id.uuidString < $1.id.uuidString
    }
    return ScreenshotProposal(matches: similar, isSimilar: !similar.isEmpty)
  }
}
