import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Провести» on random payments — in rubles, dollars and euros, for me or for somebody who
/// gives some or all of it back in another currency, with and without the rates — against the
/// rule written out: the parts always add up to what was paid, the part given back is the
/// promised return converted through rubles and never more than the charge (the whole charge
/// when it cannot be converted), the key names the payment and the due date, the payment moves
/// on to its next due date — or ends —, and deleting the operation brings the due date back.
@Suite("«Провести» on random payments")
struct MarkAsPaidPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...60)
  static let currencies: [CurrencyCode] = [.rub, .usd, .eur]

  struct Case {
    var payment: ScheduledPayment
    var due: DateOnly
    var amount: AmountE4
    var paidAt: Decimal?
    var rubPerUnit: [CurrencyCode: Decimal]
    var updatePrice: Bool
    var prices: [SubscriptionPrice]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed &* 61 &+ 9)
      let currency = random.choice(from: MarkAsPaidPropertyTests.currencies)
      let next = Fx.day("2026-09-01").adding(days: random.int(in: 0...60))
      payment = ScheduledPayment(
        id: Fx.id(180), name: "Payment",
        amountE4: AmountE4(raw: Int64(random.int(in: 1...90_000)) * 1_000),
        currency: currency, categoryId: Fx.housing, paymentMethodId: Fx.card,
        freq: random.choice(from: [Frequency.weekly, .monthly, .yearly]),
        interval: random.int(in: 1...3), nextDate: next)
      payment.day = payment.freq == .weekly ? next.weekday : next.day
      payment.month = payment.freq == .yearly ? next.month : nil
      if random.chance(1, outOf: 4) {
        payment.endDate = next.adding(days: random.int(in: 0...400))
      }
      if random.chance(1, outOf: 2) {
        payment.reimbursable = true
        payment.debtorPersonId = Fx.id(40)
        if random.chance(2, outOf: 3) {
          payment.reimbursementAmountE4 = AmountE4(raw: Int64(random.int(in: 0...120_000)) * 1_000)
          payment.reimbursementCurrency =
            random.chance(1, outOf: 3)
            ? nil : random.choice(from: MarkAsPaidPropertyTests.currencies)
        }
      }
      // The due date paid: `next_date` most often, an earlier one now and then.
      let rule = RecurrenceRule(payment: payment)
      due = random.chance(4, outOf: 5) ? next : ScheduledMatching.previous(before: next, rule: rule)
      amount = AmountE4(raw: Int64(random.int(in: 1...100_000)) * 1_000)
      paidAt = random.chance(1, outOf: 2) ? Decimal(random.int(in: 5_000...12_000)) / 100 : nil
      rubPerUnit = [:]
      if random.chance(3, outOf: 4) {
        rubPerUnit[.usd] = Decimal(random.int(in: 8_000...9_900)) / 100
      }
      if random.chance(1, outOf: 2) {
        rubPerUnit[.eur] = Decimal(random.int(in: 9_000...11_000)) / 100
      }
      updatePrice = random.chance(1, outOf: 2)
      prices =
        random.chance(1, outOf: 3)
        ? [
          SubscriptionPrice(
            paymentId: payment.id, date: due.adding(days: -random.int(in: 0...30)),
            amountE4: AmountE4(raw: Int64(random.int(in: 1...90_000)) * 1_000))
        ] : []
    }

    /// Rubles for one unit of `code` as the payment knows them: the ruble is one, the payment's
    /// own currency is the rate it was paid at when given, any other the bank's rate.
    func perUnit(_ code: CurrencyCode) -> Decimal? {
      if code == .rub { return 1 }
      let foreign = payment.currency != .rub
      if code == payment.currency, foreign, let paidAt { return paidAt }
      return rubPerUnit[code].flatMap { $0 > 0 ? $0 : nil }
    }

    /// What the person gives back of this charge, in the payment's currency.
    var returned: AmountE4 {
      guard payment.reimbursable else { return .zero }
      guard let promised = payment.reimbursementAmountE4 else { return amount }
      let code = payment.reimbursementCurrency ?? payment.currency
      let inPaymentCurrency: AmountE4
      if code == payment.currency {
        inPaymentCurrency = promised
      } else {
        guard let from = perUnit(code), let to = perUnit(payment.currency) else { return amount }
        inPaymentCurrency = SubscriptionMath.rounded(promised.decimal * from / to)
      }
      return min(max(.zero, inPaymentCurrency), amount)
    }

    /// The payment after the charge: past `due` to its next due date, or ended past its end;
    /// a due date before `next_date` leaves it where it is.
    var advanced: ScheduledPayment {
      var copy = payment
      guard let next = payment.nextDate, due >= next else { return copy }
      var following = due.adding(days: 1)
      while !PlainCalendar.isOnTheRule(following, of: payment) {
        following = following.adding(days: 1)
      }
      copy.nextDate = payment.endDate.map { following > $0 } == true ? nil : following
      return copy
    }
  }

  func plan(_ one: Case) throws -> MarkAsPaidPlan {
    try ScheduledRules.markAsPaid(
      one.payment, due: one.due, amount: one.amount, occurredAt: Fx.at(one.due.iso, 12),
      paidAt: one.paidAt, rubPerUnit: one.rubPerUnit, updatePrice: one.updatePrice,
      prices: one.prices)
  }

  /// The parts: what is given back, reimbursable and owed by the debtor, then my part for the
  /// rest when anything is left — adding up to the charge, each above zero.
  @Test(arguments: seeds)
  func thePartsAreTheReturnAndMyRest(_ seed: UInt64) throws {
    let one = Case(seed: seed)
    let plan = try plan(one)
    let parts = plan.draft.parts
    #expect(AmountE4.sum(parts.map(\.amount)) == one.amount, "seed \(seed)")
    #expect(parts.allSatisfy { $0.amount.raw > 0 }, "seed \(seed)")
    let returned = one.returned
    if returned.raw > 0 {
      #expect(parts.first?.reimbursable == true, "seed \(seed)")
      #expect(parts.first?.amount == returned, "seed \(seed)")
      #expect(parts.first?.debtorPersonId == Fx.id(40))
      #expect(parts.first?.reimbursementStatus == .expected)
      #expect(parts.count == (returned == one.amount ? 1 : 2), "seed \(seed)")
    } else {
      #expect(parts.map(\.reimbursable) == [false], "seed \(seed)")
    }
    #expect(parts.allSatisfy { $0.categoryId == Fx.housing })
    #expect(plan.draft.kind == .expense)
    #expect(plan.draft.currency == one.payment.currency)
    #expect(plan.draft.amount == one.amount)
    #expect(plan.draft.paymentMethodId == Fx.card)
    // A rate typed for a foreign charge is kept as typed; a ruble charge has none.
    let foreign = one.payment.currency != .rub
    #expect(plan.draft.rate == (foreign ? one.paidAt : nil), "seed \(seed)")
  }

  /// The key names the payment and the due date; the payment moves on past the due date to the
  /// next day of its rule — or ends past its end —, and an earlier due date leaves it as it is.
  /// The new price is written only when asked for and different from the price of that day.
  @Test(arguments: seeds)
  func theKeyTheNextDateAndThePrice(_ seed: UInt64) throws {
    let one = Case(seed: seed)
    let plan = try plan(one)
    #expect(
      plan.externalId == "sched:\(one.payment.id.uuidString.lowercased()):\(one.due.iso)",
      "seed \(seed)")
    #expect(plan.payment == one.advanced, "seed \(seed)")
    let dayPrice =
      one.prices.last { $0.date <= one.due }?.amountE4 ?? one.payment.amountE4
    let changes = one.updatePrice && one.amount != dayPrice
    #expect((plan.newPrice != nil) == changes, "seed \(seed)")
    #expect(plan.newPrice?.date == (changes ? one.due : nil))
    #expect(plan.newPrice?.amountE4 == (changes ? one.amount : nil))
  }

  /// Deleting the operation of the due date right before `next_date` — the one «Провести»
  /// moved the payment past — brings that due date back; a due date further behind brings
  /// nothing back: the schedule has moved on since.
  @Test(arguments: seeds)
  func deletingTheChargeBringsTheDueDateBack(_ seed: UInt64) throws {
    let one = Case(seed: seed)
    let plan = try plan(one)
    let reopened = ScheduledRules.reopened(plan.payment, due: one.due)
    if one.due == one.payment.nextDate {
      #expect(reopened == one.payment, "seed \(seed)")
    } else {
      var back = one.payment
      back.nextDate = one.due
      #expect(reopened == back, "seed \(seed)")
    }
    // Two due dates behind `next_date`: nothing comes back.
    if let next = plan.payment.nextDate {
      let rule = RecurrenceRule(payment: one.payment)
      let behind = ScheduledMatching.previous(
        before: ScheduledMatching.previous(before: next, rule: rule), rule: rule)
      #expect(ScheduledRules.reopened(plan.payment, due: behind) == nil, "seed \(seed)")
    }
  }

  /// A charge of zero or less is refused.
  @Test func aChargeOfNothingIsRefused() {
    let payment = Fx.payment(1, "Rent", "1000", day: 15, next: "2026-09-15")
    for amount in [AmountE4.zero, Fx.money("-1")] {
      #expect(throws: ScheduledIssue.nonPositiveAmount) {
        try ScheduledRules.markAsPaid(
          payment, due: Fx.day("2026-09-15"), amount: amount, occurredAt: Fx.now)
      }
    }
  }

  /// The random cases reach every branch: a partial return and a whole one, a return converted
  /// through rubles and one that could not be, a due date before `next_date`, an end reached.
  @Test func theCasesReachEveryBranch() {
    var partial = 0
    var whole = 0
    var converted = 0
    var unconverted = 0
    var earlier = 0
    var ended = 0
    for seed in Self.seeds {
      let one = Case(seed: seed)
      let returned = one.returned
      if returned.raw > 0, returned < one.amount { partial += 1 }
      if returned == one.amount, one.payment.reimbursable { whole += 1 }
      if let code = one.payment.reimbursementCurrency, code != one.payment.currency,
        one.payment.reimbursementAmountE4 != nil
      {
        if one.perUnit(code) != nil && one.perUnit(one.payment.currency) != nil {
          converted += 1
        } else {
          unconverted += 1
        }
      }
      if one.due != one.payment.nextDate { earlier += 1 }
      if one.advanced.nextDate == nil { ended += 1 }
    }
    for (name, count) in [
      ("partial", partial), ("whole", whole), ("converted", converted),
      ("unconverted", unconverted), ("earlier", earlier), ("ended", ended),
    ] {
      #expect(count >= 2, "\(name)")
    }
  }
}
