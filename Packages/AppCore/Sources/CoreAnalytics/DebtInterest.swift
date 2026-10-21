import CoreAccounting
import CoreKit
import Foundation

/// A payment of a loan that accrues interest, parted the way the bank parts it: the interest
/// accrued so far first, the rest off the principal (`DebtInterest.split`).
public struct DebtPaymentSplit: Hashable, Sendable {
  /// The part that pays interest: on a loan whose payments are not expenses, the part that is.
  public var interestE4: AmountE4
  /// The part that lowers what is owed.
  public var principalE4: AmountE4

  public init(interestE4: AmountE4, principalE4: AmountE4) {
    self.interestE4 = interestE4
    self.principalE4 = principalE4
  }
}

/// The interest a bank charges on a loan that accrues it (`Debt.accruesInterest`): worked out
/// from the journal when it is read, never stored. A debt that does not accrue interest reads
/// exactly as its journal says.
///
/// Interest accrues day by day on the principal (`InterestMath.accrue`: a day earns on the
/// balance it starts with, at the debt's yearly rate over the days of its year). Each payment,
/// in the order they were made, first pays the interest accrued since the payment before —
/// rounded to the cent once, at the payment — and only the rest of its money lowers the
/// principal. The journal holds the whole money of the payment, so the interest it paid comes
/// back as a line of its own: an `adjustment` of plus that much on the payment's day, whose id is
/// the payment's id XOR «debtinterestline». Interest a payment did not cover is carried to the
/// next one. On a loan with a grace period, what is carried when the main schedule starts — the
/// share of the interest the grace dues did not ask for — joins the principal on `mainFrom`: an
/// `adjustment` whose id is the debt's id XOR «debtinterestcap!». These lines live only in what
/// is read: they are never stored, exported, edited or undone, and they move no money.
public enum DebtInterest {
  /// The mask of the line of the interest a payment paid.
  public static let lineMask: [UInt8] = Array("debtinterestline".utf8)
  /// The mask of the line of the interest that joins the principal when the main schedule starts.
  public static let capitalizedMask: [UInt8] = Array("debtinterestcap!".utf8)

  /// The id of the line of the interest the payment `paymentId` paid.
  public static func lineId(forPayment paymentId: UUID) -> UUID {
    xor(paymentId, with: lineMask)
  }

  /// The id of the line of the interest that joins the principal of `debtId` at the switch.
  public static func capitalizedLineId(forDebt debtId: UUID) -> UUID {
    xor(debtId, with: capitalizedMask)
  }

  /// The journal of `debt` as the interest makes it, through `through`: the lines as they are,
  /// and, for a debt that accrues interest, the interest each payment through `through` pays
  /// first, as a line of its own that only lives in what is read. Its balance is the principal.
  public static func effectiveJournal(
    debt: Debt, journal: [DebtEntry], through: DateOnly, calendar: CalendarContext
  ) -> [DebtEntry] {
    guard let walk = walk(debt: debt, journal: journal, through: through, calendar: calendar)
    else { return journal }
    return journal + walk.lines
  }

  /// The interest accrued on `debt` and not paid yet, through `through`, to the cent — zero for
  /// a debt that does not accrue it.
  public static func accruedE4(
    debt: Debt, journal: [DebtEntry], through: DateOnly, calendar: CalendarContext
  ) -> AmountE4 {
    walk(debt: debt, journal: journal, through: through, calendar: calendar)?.accruedE4 ?? .zero
  }

  /// The interest each payment of the journal through `through` paid, by the id of its line;
  /// payments that paid none are left out. Empty for a debt that does not accrue interest.
  public static func interestPaid(
    debt: Debt, journal: [DebtEntry], through: DateOnly, calendar: CalendarContext
  ) -> [UUID: AmountE4] {
    walk(debt: debt, journal: journal, through: through, calendar: calendar)?.interestByPayment
      ?? [:]
  }

  /// A payment of `amount` on `day` toward `debt`, parted into the interest it pays first and the
  /// principal: the interest is what is accrued and unpaid through `day`, after every payment of
  /// the journal on that day or before it, to the cent, never more than `amount`. `replacing` —
  /// the line of the payment being edited — is left out of the journal first. A debt that does
  /// not accrue interest pays principal alone.
  ///
  /// On a debt whose payments are not expenses — an education loan, whose tranches were the
  /// expense — the interest part is the expense of the payment, in «Кредиты».
  public static func split(
    payment amount: AmountE4, on day: DateOnly, debt: Debt, journal: [DebtEntry],
    calendar: CalendarContext, replacing: UUID? = nil
  ) -> DebtPaymentSplit {
    let money = amount.magnitude
    let lines = replacing.map { id in journal.filter { $0.id != id } } ?? journal
    guard
      let walk = walk(
        debt: debt, journal: lines, through: day, calendar: calendar, extra: (day, money))
    else { return DebtPaymentSplit(interestE4: .zero, principalE4: money) }
    let interest = min(walk.extraInterestE4, money)
    return DebtPaymentSplit(interestE4: interest, principalE4: money - interest)
  }

  // MARK: - The walk

  /// Everything the interest of a loan makes of its journal, read once.
  public struct Reading: Hashable, Sendable {
    /// The lines of the interest — what each payment paid, what joined the principal at the
    /// switch —, in the order of the days; they live only in what is read.
    public var lines: [DebtEntry] = []
    /// The interest each payment paid, by the id of its line; none for one that paid none.
    public var interestByPayment: [UUID: AmountE4] = [:]
    /// Accrued and unpaid through the day asked about, to the cent.
    public var accruedE4: AmountE4 = .zero
    /// The interest the payment `split` adds pays.
    var extraInterestE4: AmountE4 = .zero
  }

  /// The interest of `debt` through `through` (`Reading`); `nil` for a debt that does not
  /// accrue it — or has no rate above zero —, whose journal reads as it is.
  public static func read(
    debt: Debt, journal: [DebtEntry], through: DateOnly, calendar: CalendarContext
  ) -> Reading? {
    walk(debt: debt, journal: journal, through: through, calendar: calendar)
  }

  /// `read`, with `extra` one more payment, made last on its day.
  static func walk(
    debt: Debt, journal: [DebtEntry], through: DateOnly, calendar: CalendarContext,
    extra: (day: DateOnly, money: AmountE4)? = nil
  ) -> Reading? {
    guard debt.accruesInterest, let rate = debt.interestRate, rate > 0 else { return nil }
    var result = Reading()
    var principal = AmountE4.zero
    var byDay: [DateOnly: [DebtEntry]] = [:]
    for line in journal where line.debtId == debt.id {
      guard var day = line.date ?? line.occurredAt.map(calendar.day(of:)) else {
        principal += line.amountE4
        continue
      }
      // An early repayment to a bank that takes one only on a payment day lowers the debt on
      // the next due, not on the day the money was paid.
      if line.prepay?.isEarlyRepayment == true, line.kind == .payment, !debt.prepayAnyDay {
        day = DebtPrepay.effectiveDay(debt: debt, paidOn: day)
      }
      guard day <= through else { continue }
      byDay[day, default: []].append(line)
    }
    var days = Set(byDay.keys)
    if let extra { days.insert(extra.day) }
    let ordered = days.sorted()
    guard let firstDay = ordered.first else { return result }

    // The money there was before the first day earns from it on; nothing earns before.
    var lastDay = firstDay.adding(days: -1)
    var segments: [(from: DateOnly, amount: AmountE4)] = [(lastDay, principal)]
    var carried = Decimal(0)
    let mainFrom = debt.grace?.mainFrom
    var capitalized = false

    func capitalize(on day: DateOnly) {
      capitalized = true
      let amount = InterestMath.cents(carried)
      guard amount.raw > 0 else { return }
      carried -= amount.decimal
      principal += amount
      result.lines.append(
        DebtEntry(
          id: capitalizedLineId(forDebt: debt.id), debtId: debt.id, date: day, amountE4: amount,
          kind: .adjustment))
      segments.append((day, principal))
    }

    func pay(_ money: AmountE4, accrued: inout Decimal) -> AmountE4 {
      let due = max(InterestMath.cents(accrued), .zero)
      let paid = min(money, due)
      accrued -= paid.decimal
      return paid
    }

    for day in ordered {
      if let mainFrom, !capitalized, day >= mainFrom { capitalize(on: mainFrom) }
      let lines = byDay[day] ?? []
      let payments = lines.filter { $0.kind == .payment && $0.amountE4.isNegative }
        .sorted { left, right in
          let leftAt = left.occurredAt ?? calendar.startOfDay(day)
          let rightAt = right.occurredAt ?? calendar.startOfDay(day)
          if leftAt != rightAt { return leftAt < rightAt }
          if left.closesTerm != right.closesTerm { return !left.closesTerm }
          if left.amountE4.magnitude != right.amountE4.magnitude {
            return left.amountE4.magnitude < right.amountE4.magnitude
          }
          return left.id.uuidString < right.id.uuidString
        }
      let isExtraDay = extra?.day == day
      if !payments.isEmpty || isExtraDay {
        var accrued =
          carried
          + InterestMath.accrue(segments: segments, percent: rate, after: lastDay, through: day)
        lastDay = day
        for payment in payments {
          let paid = pay(payment.amountE4.magnitude, accrued: &accrued)
          principal += payment.amountE4 + paid
          guard paid.raw > 0 else { continue }
          result.interestByPayment[payment.id] = paid
          result.lines.append(
            DebtEntry(
              id: lineId(forPayment: payment.id), debtId: debt.id, date: day, amountE4: paid,
              kind: .adjustment, occurredAt: payment.occurredAt))
        }
        if isExtraDay, let extra {
          let paid = pay(extra.money, accrued: &accrued)
          result.extraInterestE4 = paid
          principal += paid - extra.money
        }
        carried = max(accrued, 0)
      }
      for line in lines where !(line.kind == .payment && line.amountE4.isNegative) {
        principal += line.amountE4
      }
      segments.append((day, principal))
    }
    if let mainFrom, !capitalized, mainFrom <= through { capitalize(on: mainFrom) }
    let open =
      carried
      + InterestMath.accrue(segments: segments, percent: rate, after: lastDay, through: through)
    result.accruedE4 = max(InterestMath.cents(open), .zero)
    return result
  }

  /// An id XOR a 16-byte mask: the same on every read, never the id it came from.
  static func xor(_ id: UUID, with mask: [UInt8]) -> UUID {
    precondition(mask.count == 16, "a mask covers the 16 bytes of an id")
    var bytes = id.uuid
    withUnsafeMutableBytes(of: &bytes) { raw in
      for index in raw.indices { raw[index] ^= mask[index] }
    }
    return UUID(uuid: bytes)
  }
}
