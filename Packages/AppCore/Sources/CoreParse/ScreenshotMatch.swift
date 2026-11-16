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
  /// What the account was charged when the operation is in another currency than the account
  /// (`Transaction.accountCurrency`, `accountAmountE4`): a bank screenshot of a purchase abroad
  /// shows this sum. `nil` when the operation is in the account's own currency.
  public var chargedCurrency: CurrencyCode?
  public var chargedAmount: AmountE4?
  /// The operation's note: where the purchase was, as the owner wrote it.
  public var note: String?

  public init(
    id: UUID, accountID: UUID, kind: TransactionKind, currency: CurrencyCode,
    amount: AmountE4, occurredAt: Date, timeZoneID: String? = nil, isTransfer: Bool = false,
    chargedCurrency: CurrencyCode? = nil, chargedAmount: AmountE4? = nil, note: String? = nil
  ) {
    self.id = id
    self.accountID = accountID
    self.kind = kind
    self.currency = currency
    self.amount = amount
    self.occurredAt = occurredAt
    self.timeZoneID = timeZoneID
    self.isTransfer = isTransfer
    self.chargedCurrency = chargedCurrency
    self.chargedAmount = chargedAmount
    self.note = note
  }

  /// The operation's sum in `currency`: its own, or what the account was charged; `nil` when
  /// neither is in that currency.
  func amount(in currency: CurrencyCode) -> AmountE4? {
    if self.currency == currency { return amount }
    if chargedCurrency == currency, let chargedAmount { return chargedAmount }
    return nil
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
      let charged =
        transaction.accountCurrency.flatMap { $0 == transaction.currency ? nil : $0 }
      return ScreenshotCandidate(
        id: transaction.id, accountID: account, kind: transaction.kind,
        currency: transaction.currency, amount: transaction.amountE4,
        occurredAt: transaction.occurredAt, timeZoneID: transaction.timeZoneId,
        chargedCurrency: charged,
        chargedAmount: charged == nil ? nil : transaction.accountAmountE4,
        note: transaction.note)
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

  /// How far the time the owner typed may be from the screenshot's and still be its time: the
  /// owner writes a purchase down after paying, and rounds the clock.
  public static let timeTolerance: TimeInterval = 30 * 60

  /// Whether an operation carries a time of its own. One typed without a time sits at the app's
  /// noon of its day in the zone it was recorded in (`CalendarContext.noon(of:)`); that is no
  /// time, and is never read as 12:00.
  public static func hasOwnTime(
    _ occurredAt: Date, recordedIn zoneID: String?, calendar: CalendarContext
  ) -> Bool {
    let zone = CalendarContext(timeZone: calendar.zone(recordedIn: zoneID))
    let noon = zone.noon(of: zone.day(of: occurredAt))
    return abs(occurredAt.timeIntervalSince(noon)) >= 1
  }

  /// Exact amount, account and recorded day first. Only without an exact match are the
  /// receipt's tolerances used: up to 5 % of the screenshot's amount and 24 hours either way.
  /// Every result is a proposal for the owner to choose, never an automatic merge.
  ///
  /// The amount is the operation's own or, for one in another currency than its account, what
  /// the account was charged. The screenshot's time only orders what fits: first the operations
  /// whose own time is within `timeTolerance` of it, then those with no time of their own, then
  /// the rest, nearest first.
  public static func propose(
    amount: AmountE4, kind: TransactionKind, currency: CurrencyCode,
    accountID: UUID, day: DateOnly, time: TimeOfDay?, among candidates: [ScreenshotCandidate],
    calendar: CalendarContext
  ) -> ScreenshotProposal {
    guard amount.raw > 0 else { return ScreenshotProposal(matches: [], isSimilar: false) }
    let eligible = candidates.filter {
      $0.accountID == accountID && $0.kind == kind && ($0.amount(in: currency)?.raw ?? 0) > 0
    }
    func moment(_ candidate: ScreenshotCandidate) -> Date {
      let zone = CalendarContext(timeZone: calendar.zone(recordedIn: candidate.timeZoneID))
      return zone.moment(day, hour: time?.hour ?? 12, minute: time?.minute ?? 0)
    }
    func distance(_ candidate: ScreenshotCandidate) -> TimeInterval {
      abs(candidate.occurredAt.timeIntervalSince(moment(candidate)))
    }
    func timed(_ candidate: ScreenshotCandidate) -> Bool {
      hasOwnTime(candidate.occurredAt, recordedIn: candidate.timeZoneID, calendar: calendar)
    }
    // 0: its own time is the screenshot's; 1: no time of its own; 2: another time.
    func rank(_ candidate: ScreenshotCandidate) -> Int {
      guard time != nil else { return 0 }
      guard timed(candidate) else { return 1 }
      return distance(candidate) <= timeTolerance ? 0 : 2
    }
    func ordered(_ left: ScreenshotCandidate, _ right: ScreenshotCandidate) -> Bool {
      if rank(left) != rank(right) { return rank(left) < rank(right) }
      if distance(left) != distance(right) { return distance(left) < distance(right) }
      return left.id.uuidString < right.id.uuidString
    }
    func recordedDay(_ candidate: ScreenshotCandidate) -> DateOnly {
      calendar.day(of: candidate.occurredAt, recordedIn: candidate.timeZoneID)
    }
    let exact = eligible.filter {
      $0.amount(in: currency) == amount && recordedDay($0) == day
    }.sorted(by: ordered)
    if !exact.isEmpty { return ScreenshotProposal(matches: exact, isSimilar: false) }
    // A date alone cannot establish a 24-hour distance. The screen asks for the clock
    // before offering approximate matches, rather than inventing a moment for the screenshot.
    guard time != nil else { return ScreenshotProposal(matches: [], isSimilar: false) }
    func difference(_ candidate: ScreenshotCandidate) -> Int64 {
      abs((candidate.amount(in: currency)?.raw ?? 0) - amount.raw)
    }
    // An operation with no time of its own may have been made at any hour of its day: within
    // 24 hours means the day of the screenshot or a neighbouring one.
    func near(_ candidate: ScreenshotCandidate) -> Bool {
      guard timed(candidate) else {
        let gap = calendar.startOfDay(recordedDay(candidate))
          .timeIntervalSince(calendar.startOfDay(day))
        return abs((gap / 86_400).rounded()) <= 1
      }
      return distance(candidate) <= ReceiptMatch.window
    }
    let similar = eligible.filter {
      difference($0) <= ReceiptMatch.tolerance(of: amount) && near($0)
    }.sorted {
      if difference($0) != difference($1) { return difference($0) < difference($1) }
      return ordered($0, $1)
    }
    return ScreenshotProposal(matches: similar, isSimilar: !similar.isEmpty)
  }
}
