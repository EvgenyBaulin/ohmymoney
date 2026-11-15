import CoreAnalytics
import CoreKit
import Foundation

/// The interest the owner paid in a year, one line per payment: the operations the app wrote
/// for interest it was told of (`ccinterest:`, `debtinterest:`, `debtmarkup:`) plus the interest
/// the payments of a loan that accrues it paid, those the app did not write down on their own
/// counted once. The bank's fees of a year and the deduction for the interest of a mortgage both
/// read these lines, so the two never count the interest of one payment differently.
public enum LoanInterestPaid {
  /// One payment's interest, in rubles.
  public struct Line: Hashable, Sendable {
    /// The debt the interest was paid on; `nil` for a credit card's interest.
    public var debtId: UUID?
    public var day: DateOnly
    public var rub: AmountE4

    public init(debtId: UUID?, day: DateOnly, rub: AmountE4) {
      self.debtId = debtId
      self.day = day
      self.rub = rub
    }
  }

  /// The prefixes of the operations the app writes for interest it was told of.
  static let interestPrefixes = ["ccinterest:", "debtinterest:", "debtmarkup:"]

  /// The lines of `year`, on the day of each payment.
  public static func lines(
    _ year: Int, ledger: Ledger, rubPerUnit: [CurrencyCode: Decimal]
  ) -> [Line] {
    let dataset = ledger.dataset
    let journal = dataset.planning.debtEntries
    var debtOfPayment: [String: UUID] = [:]
    for entry in journal where entry.kind == .payment {
      if let id = entry.transactionId { debtOfPayment[id.uuidString.lowercased()] = entry.debtId }
    }
    var lines: [Line] = []
    var written = Set<String>()
    for entry in dataset.entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        let external = transaction.externalId,
        interestPrefixes.contains(where: { external.hasPrefix($0) })
      else { continue }
      let day = ledger.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      guard day.year == year else { continue }
      let fields = external.split(separator: ":")
      let payment = fields.count >= 2 ? String(fields[1]).lowercased() : nil
      if fields.first == "debtinterest", let payment { written.insert(payment) }
      let debt =
        fields.first == "ccinterest"
        ? nil : (transaction.creditDebtId ?? payment.flatMap { debtOfPayment[$0] })
      lines.append(Line(debtId: debt, day: day, rub: transaction.amountRubE4))
    }
    for debt in dataset.debts
    where debt.direction == .iOwe && debt.accruesInterest && !debt.isDeleted {
      let mine = journal.filter { $0.debtId == debt.id }
      let paid = DebtInterest.interestPaid(
        debt: debt, journal: mine, through: DateOnly(year: year, month: 12, day: 31),
        calendar: ledger.calendar)
      let rate = debt.currency == .rub ? Decimal(1) : (rubPerUnit[debt.currency] ?? 0)
      for entry in mine where entry.kind == .payment {
        guard let day = entry.date, day.year == year,
          let amount = paid[entry.id], amount.raw > 0
        else { continue }
        if let transactionId = entry.transactionId,
          written.contains(transactionId.uuidString.lowercased())
        {
          continue
        }
        let rub = debt.currency == .rub ? amount : InterestMath.cents(amount.decimal * rate)
        lines.append(Line(debtId: debt.id, day: day, rub: rub))
      }
    }
    return lines
  }
}
