import CoreKit
import Foundation

/// What is still owed on one part after a money back that does not close it.
public struct OwedRemainder: Hashable, Sendable {
  public var partId: UUID
  /// In rubles.
  public var remainingRubE4: AmountE4

  public init(partId: UUID, remainingRubE4: AmountE4) {
    self.partId = partId
    self.remainingRubE4 = remainingRubE4
  }
}

/// Why money back cannot be recorded as it is.
public enum MoneyBackRefusal: Hashable, Sendable {
  /// The person owes nothing: the money is income, and is recorded as income.
  case owesNothing
  /// The person owes no part, but owes on an open «Мне должны» debt: the money is a repayment
  /// of that debt.
  case owesOnDebt(UUID)
  /// Every part the person owes is on a rate still provisional: the rubles a link fixes now
  /// would drift from the refined ones.
  case onlyProvisional
  /// The money back's own rate is still provisional and was not typed by hand: the rubles it
  /// closes parts with are not known yet.
  case provisionalRate
  /// The money is more than the parts it can close, while other parts of the person wait on a
  /// rate still provisional: the money over would be income now and close those parts later
  /// all the same — counted twice. It is recorded once their rates are known, or by hand.
  case provisionalPartsOwed
}

/// How a money back is spread over what the person owes, before anything is written.
public struct MoneyBackPlan: Hashable, Sendable {
  /// The currency the money came in.
  public var currency: CurrencyCode
  /// One share per part the money reaches, oldest first; `amountE4` is the rubles of its link.
  public var allocations: [ReimbursementAllocation]
  /// The parts that are settled: `returned` from now on.
  public var closes: [UUID]
  /// «Останется должен»: what is still owed on every part that stays open, in rubles.
  public var stillOwed: [OwedRemainder]
  /// Money on top of everything owed, in the money back's currency: income in «Доплаты».
  public var surplus: AmountE4
  public var surplusRub: AmountE4
  /// Parts left alone because their rate is still provisional; the sheet says so.
  public var skippedProvisional: [UUID]
  /// Set when the money back cannot be recorded as it is; nothing else is filled then.
  public var refusal: MoneyBackRefusal?

  public init(
    currency: CurrencyCode = .rub, allocations: [ReimbursementAllocation] = [],
    closes: [UUID] = [], stillOwed: [OwedRemainder] = [], surplus: AmountE4 = .zero,
    surplusRub: AmountE4 = .zero, skippedProvisional: [UUID] = [],
    refusal: MoneyBackRefusal? = nil
  ) {
    self.currency = currency
    self.allocations = allocations
    self.closes = closes
    self.stillOwed = stillOwed
    self.surplus = surplus
    self.surplusRub = surplusRub
    self.skippedProvisional = skippedProvisional
    self.refusal = refusal
  }

  /// The rubles that reach the parts.
  public var allocatedRubE4: AmountE4 { AmountE4.sum(allocations.map(\.amountE4)) }
}

/// Money a person gives back for what I paid for them.
///
/// The money closes the person's parts oldest first. A part it covers only partly stays open,
/// waiting for the rest — nothing is counted short. Money on top of everything owed is income
/// in «Доплаты». Everything is worked out in the currency the money came in, at its own rate:
/// 50 dollars back for a part of 50 dollars close it exactly, whatever the rates did in
/// between, and leave nothing over.
///
/// A small tolerance keeps the drift of rates from leaving crumbs: a part that falls short of
/// its rubles by no more than that is closed — rate drift is neither spending nor income. Money
/// over is another matter: whatever comes back above every part is income, down to the kopeck
/// (4,780 ₽ back for a part of 4,750 ₽ is 30 ₽ of income); only what is below a kopeck is the
/// rounding of the shares and is not written.
public enum MoneyBack {
  /// One ruble.
  static let toleranceFloor = AmountE4(whole: 1)
  /// Fifty rubles.
  static let toleranceCeiling = AmountE4(whole: 50)
  /// One kopeck: money over by less is the rounding of the shares, never income.
  public static let crumb = AmountE4(raw: 100)

  /// How far the rubles of a part may miss and still be settled: nothing when the part and the
  /// money are both in rubles, otherwise 1 % of the part's rubles, never below 1 ₽ and never
  /// above 50 ₽.
  public static func tolerance(partRub: AmountE4, foreignInvolved: Bool) -> AmountE4 {
    guard foreignInvolved else { return .zero }
    let share = (try? AmountE4(decimal: partRub.magnitude.decimal / 100)) ?? toleranceCeiling
    return min(max(toleranceFloor, share), toleranceCeiling)
  }

  /// Spreads `received` — in `currency`, `receivedRub` in rubles — from `person` over the parts
  /// the person owes (`owed`: that person's parts), oldest first.
  ///
  /// * The money back's own rate is `receivedRub ÷ received`. When it is still provisional
  ///   and was not typed (`rateProvisional`), nothing is spread: `.provisionalRate`.
  /// * A part on a provisional rate is left alone and listed in `skippedProvisional`.
  /// * Each part needs what is left of it in `currency`: its own remaining amount when it was
  ///   bought in that currency, otherwise its remaining rubles at the money back's rate. The
  ///   money takes what it can; a part it covers closes, and its link is exactly what was
  ///   left of its rubles. A part it covers only partly keeps waiting with the rest — unless
  ///   the rest is within the tolerance, which closes it.
  /// * What is left over is the surplus, and its rubles are the rubles received less the rubles
  ///   the parts took at the money back's rate, so every ruble that came in is written once.
  ///   Every surplus is income, however small, but for less than a kopeck (`crumb`): that is
  ///   the rounding of the shares. Money that ends exactly on a part's need closes it with its
  ///   own rubles, whatever the rubles received differ by — the drift of the rate. Money over
  ///   while parts on a provisional rate are still owed is not income: nothing is spread,
  ///   `.provisionalPartsOwed`.
  /// * No part owed: `.owesOnDebt` when the person has an open «Мне должны» debt among
  ///   `openDebts` — theirs, never another person's — with something still owed on it
  ///   (`debtBalances`; a debt missing there counts as owing), otherwise `.owesNothing`: money
  ///   from somebody whose debt is at zero is income.
  public static func plan(
    received: AmountE4, currency: CurrencyCode, receivedRub: AmountE4, rateProvisional: Bool,
    person: UUID, owed: [OwedPart], openDebts: [Debt], debtBalances: [UUID: AmountE4] = [:]
  ) -> MoneyBackPlan {
    let waiting = owed.filter { $0.remainingRubE4.raw > 0 }.sorted(by: MyExpensesRule.oldestFirst)
    guard !waiting.isEmpty else {
      let debt = openDebts.filter {
        !$0.closed && $0.direction == .owedToMe && $0.personId == person
          && (debtBalances[$0.id].map { $0.raw > 0 } ?? true)
      }
      .min { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
      return MoneyBackPlan(
        currency: currency, refusal: debt.map { .owesOnDebt($0.id) } ?? .owesNothing)
    }
    guard !rateProvisional else {
      return MoneyBackPlan(currency: currency, refusal: .provisionalRate)
    }
    let skipped = waiting.filter(\.rateProvisional)
    let parts = waiting.filter { !$0.rateProvisional }
    guard !parts.isEmpty else {
      return MoneyBackPlan(
        currency: currency, stillOwed: remainders(of: skipped),
        skippedProvisional: skipped.map(\.partId), refusal: .onlyProvisional)
    }

    let rate =
      currency == .rub || received.isZero
      ? Decimal(1) : receivedRub.decimal / received.decimal
    var plan = MoneyBackPlan(currency: currency, skippedProvisional: skipped.map(\.partId))
    var left = max(received, .zero)
    // What the parts took, in rubles at the money back's own rate: the rubles of their links,
    // except for a part bought in the money back's currency, whose link is at the part's rate —
    // the difference is drift of the rate, neither income nor spending.
    var takenRub = AmountE4.zero
    for part in parts {
      let need = need(of: part, in: currency, rate: rate)
      let take = min(need, left)
      guard take.raw > 0 || need.isZero else {
        plan.stillOwed.append(
          OwedRemainder(partId: part.partId, remainingRubE4: part.remainingRubE4))
        continue
      }
      left = left - take
      let link: AmountE4
      if take == need {
        link = part.remainingRubE4
      } else if part.currency != currency, receivedRub - takenRub > .zero {
        // The part takes the rest of the money: the rest of the rubles received, not the rest
        // converted again — 20 $ received as 1,850 ₽ close 1,000 ₽ and then exactly 850 ₽.
        link = min(receivedRub - takenRub, part.remainingRubE4)
      } else {
        link = rubles(of: take, for: part, in: currency, rate: rate)
      }
      plan.allocations.append(ReimbursementAllocation(partId: part.partId, amountE4: link))
      takenRub = takenRub + (part.currency == currency ? convert(take, rate: rate) : link)
      let rest = part.remainingRubE4 - link
      let foreign = part.currency != .rub || currency != .rub
      if take == need || rest <= tolerance(partRub: part.amountRubE4, foreignInvolved: foreign) {
        plan.closes.append(part.partId)
      } else {
        plan.stillOwed.append(OwedRemainder(partId: part.partId, remainingRubE4: rest))
      }
    }
    plan.stillOwed += remainders(of: skipped)

    // The rubles received less the rubles the parts took, not what is left converted again:
    // that missed by the rounding of every part's share (50 $ at 95 ₽ over a part of 4,500 ₽
    // came to 4,750.0020 ₽ for 4,750 ₽ received).
    let surplusRub = left.isZero ? .zero : max(receivedRub - takenRub, .zero)
    if left.raw > 0, surplusRub < crumb {
      left = .zero
    }
    if left.raw > 0, !skipped.isEmpty {
      return MoneyBackPlan(
        currency: currency, stillOwed: remainders(of: waiting),
        skippedProvisional: skipped.map(\.partId), refusal: .provisionalPartsOwed)
    }
    plan.surplus = left
    plan.surplusRub = left.isZero ? .zero : surplusRub
    return plan
  }

  /// The records a plan asks to write: a link for every part the money reached, the parts it
  /// settles, and the surplus — income in «Доплаты», in the money back's currency, on the
  /// account the money came onto. Money back spread automatically is never short.
  public static func outcome(
    _ plan: MoneyBackPlan, reimbursementTxId: UUID, accountId: UUID?,
    makeId: () -> UUID = { UUID() }
  ) -> ReimbursementOutcome {
    let links = plan.allocations.map {
      ReimbursementLink(
        id: makeId(), reimbursementTxId: reimbursementTxId, partId: $0.partId,
        amountE4: $0.amountE4)
    }
    let surplus =
      plan.surplus.raw > 0
      ? SurchargeIncome(
        amountE4: plan.surplus, currency: plan.currency, amountRubE4: plan.surplusRub,
        accountId: accountId)
      : nil
    return ReimbursementOutcome(
      reimbursementTxId: reimbursementTxId, allocations: plan.allocations, links: links,
      closedPartIds: plan.closes, surplus: surplus, shortfalls: [])
  }

  /// The income a surplus is written as: in the system Surcharges category (`categoryId`), in
  /// the currency the money came in, on the account it came onto, at the moment of its money
  /// back, keyed `reimb:<money back>:surplus` so that deleting the money back takes it along.
  /// One builder for the sheets, the entry line and the storage layer's re-balancing, so a
  /// surplus is the same row whoever writes it.
  ///
  /// `rate` is the rate the money back itself came at, its rubles over its amount: the income
  /// shows that one, while its rubles are exactly `surplus.amountRubE4`. Without it the rate is
  /// the surplus's rubles over its amount.
  public static func surplusEntry(
    _ surplus: SurchargeIncome, of moneyBackId: UUID, on moment: Date, now: Date,
    rate: Decimal? = nil, rateDate: DateOnly? = nil, categoryId: UUID, note: String?,
    id: UUID = UUID()
  ) throws -> TransactionEntry {
    let foreign = surplus.currency != .rub && !surplus.amountE4.isZero
    var draft = TransactionDraft(
      kind: .income, occurredAt: moment, currency: surplus.currency, amount: surplus.amountE4,
      rate: foreign
        ? rate
          ?? DecimalMath.round(surplus.amountRubE4.decimal / surplus.amountE4.decimal, scale: 6)
        : nil,
      rateDate: foreign ? rateDate : nil,
      rateSource: foreign ? .manual : nil,
      paymentMethodId: surplus.accountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .system
    draft.note = note
    let rubles = surplus.amountRubE4
    var entry = try draft.materialize(id: id, now: now, rublesConverter: { _ in rubles })
    entry.transaction.externalId = ReimbursementCompanions.surplusKey(of: moneyBackId)
    return entry
  }

  /// «Списать остаток»: what is left of a part some money already came back for becomes my
  /// spending — an expense in rubles of what is left, in the part's category, from the account
  /// the purchase was paid from, with the purchase's description, «на кого», person and event,
  /// like a shortfall. It is a line of the books (`writeoff:<part>:<operation>`): the money left
  /// my pocket at the purchase, so it moves no money now.
  ///
  /// `operationId` is the id of the operation written; the key goes with it.
  public static func remainderWriteOff(
    part: OwedPart, occurredAt: Date, operationId: UUID, tree: CategoryTree,
    history: ManualQualityHistory = .empty, now: Date = Date()
  ) -> TransactionEntry {
    let remaining = part.remainingRubE4
    var draft = TransactionDraft(
      kind: .expense, occurredAt: occurredAt, currency: .rub, amount: remaining, note: part.note,
      paymentMethodId: part.accountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = part.categoryId
    draft.parts[0].categorySource = .system
    draft.parts[0].forWhom = part.forWhom
    draft.parts[0].forPersonId = part.forPersonId ?? part.debtorPersonId
    draft.parts[0].eventId = part.eventId
    let decision = QualityResolver.resolve(
      categoryId: part.categoryId, description: part.note, categories: tree, history: history)
    draft.parts[0].quality = decision.quality
    draft.parts[0].qualitySource = decision.source
    var entry =
      (try? draft.materialize(id: operationId, now: now))
      ?? TransactionEntry(
        transaction: Transaction(
          id: operationId, kind: .expense, occurredAt: occurredAt, amountE4: remaining,
          createdAt: now, updatedAt: now),
        parts: [])
    entry.transaction.externalId = writeOffKey(part: part.partId, operation: operationId)
    return entry
  }

  /// The key a remainder written off keeps in `external_id`.
  public static func writeOffKey(part: UUID, operation: UUID) -> String {
    OperationLink.remainderWriteOff(
      part: part.uuidString.lowercased(), operation: operation.uuidString.lowercased()
    ).externalId
  }

  // MARK: - Arithmetic

  /// What is left of the part, in `currency`.
  private static func need(of part: OwedPart, in currency: CurrencyCode, rate: Decimal) -> AmountE4
  {
    if part.currency == currency {
      guard !part.amountRubE4.isZero else { return part.amountE4 }
      let returnedOwn =
        part.returnedRubE4.decimal * part.amountE4.decimal
        / part.amountRubE4.decimal
      let rounded = (try? AmountE4(decimal: returnedOwn)) ?? .zero
      return max(.zero, part.amountE4 - rounded)
    }
    guard rate > 0 else { return part.remainingRubE4 }
    return (try? AmountE4(decimal: part.remainingRubE4.decimal / rate)) ?? part.remainingRubE4
  }

  /// The rubles of `take` in `currency` for the part: at the part's own rate when it was bought
  /// in that currency, at the money back's rate otherwise.
  private static func rubles(
    of take: AmountE4, for part: OwedPart, in currency: CurrencyCode, rate: Decimal
  ) -> AmountE4 {
    if part.currency == currency, !part.amountE4.isZero {
      let exact = take.decimal * part.amountRubE4.decimal / part.amountE4.decimal
      return min((try? AmountE4(decimal: exact)) ?? .zero, part.remainingRubE4)
    }
    return min(convert(take, rate: rate), part.remainingRubE4)
  }

  private static func convert(_ amount: AmountE4, rate: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: amount.decimal * rate)) ?? .zero
  }

  private static func remainders(of parts: [OwedPart]) -> [OwedRemainder] {
    parts.map { OwedRemainder(partId: $0.partId, remainingRubE4: $0.remainingRubE4) }
  }
}
