import CoreKit
import Foundation

@testable import CoreAccounting

/// Money back spread over what a person owes, written from the rule and not from the code: the
/// person's parts oldest first, each needing what is left of it in the money's own currency; the
/// money covers them in turn — a part is reached by the money that is left after every part
/// before it took all it needed —; a part covered whole closes with exactly what was left of its
/// rubles, a part covered partly closes only when the rest is within the drift of rates; money
/// over everything is a surplus unless it is less than a kopeck. Parts on a rate still provisional are
/// passed over and said so. All arithmetic is on whole units with exact fractions.
struct MoneyBackRuleModel: Equatable {
  var allocations: [ReimbursementAllocation] = []
  var closes: [UUID] = []
  var stillOwed: [OwedRemainder] = []
  var surplus: AmountE4 = .zero
  var surplusRub: AmountE4 = .zero
  var skippedProvisional: [UUID] = []
  var refusal: MoneyBackRefusal?

  /// The drift of rates a part's rubles may miss by: nothing in rubles alone, otherwise 1 % of
  /// the part's rubles, never below 1 ₽ nor above 50 ₽.
  static func drift(_ partRub: AmountE4, foreign: Bool) -> AmountE4 {
    guard foreign else { return .zero }
    let percent = MoneyDice.scaled(partRub.magnitude, AmountE4(raw: 1), AmountE4(raw: 100))
    return min(max(AmountE4(whole: 1), percent), AmountE4(whole: 50))
  }

  /// What is left of a part, in the money's currency: its own remaining amount when it was
  /// bought in that currency, otherwise its remaining rubles at the money's own rate.
  static func need(
    of part: OwedPart, currency: CurrencyCode, received: AmountE4, receivedRub: AmountE4
  ) -> AmountE4 {
    if part.currency == currency {
      guard !part.amountRubE4.isZero else { return part.amountE4 }
      let back = MoneyDice.scaled(part.returnedRubE4, part.amountE4, part.amountRubE4)
      return max(.zero, part.amountE4 - back)
    }
    return currency == .rub
      ? part.remainingRubE4 : MoneyDice.scaled(part.remainingRubE4, received, receivedRub)
  }

  static func plan(
    received: AmountE4, currency: CurrencyCode, receivedRub: AmountE4, rateProvisional: Bool,
    person: UUID, owed: [OwedPart], openDebts: [Debt]
  ) -> MoneyBackRuleModel {
    var model = MoneyBackRuleModel()
    let waiting = owed.filter { $0.remainingRubE4.raw > 0 }.sorted {
      ($0.occurredAt, $0.partId.uuidString) < ($1.occurredAt, $1.partId.uuidString)
    }
    guard !waiting.isEmpty else {
      let debts = openDebts.filter {
        !$0.closed && $0.direction == .owedToMe && $0.personId == person
      }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
      model.refusal = debts.first.map { .owesOnDebt($0.id) } ?? .owesNothing
      return model
    }
    if rateProvisional {
      model.refusal = .provisionalRate
      return model
    }
    let passed = waiting.filter(\.rateProvisional)
    let parts = waiting.filter { !$0.rateProvisional }
    model.skippedProvisional = passed.map(\.partId)
    let passedRemainders = passed.map {
      OwedRemainder(partId: $0.partId, remainingRubE4: $0.remainingRubE4)
    }
    guard !parts.isEmpty else {
      model.stillOwed = passedRemainders
      model.refusal = .onlyProvisional
      return model
    }

    let inRubles = currency == .rub
    func need(_ part: OwedPart) -> AmountE4 {
      Self.need(of: part, currency: currency, received: received, receivedRub: receivedRub)
    }
    /// The rubles of `take` of a part covered only partly.
    func rubles(_ take: AmountE4, of part: OwedPart) -> AmountE4 {
      if part.currency == currency {
        return MoneyDice.scaled(take, part.amountRubE4, part.amountE4)
      }
      return inRubles ? take : MoneyDice.scaled(take, receivedRub, received)
    }

    var neededBefore = AmountE4.zero
    // The rubles the parts took at the money's own rate: a link, or — for a part bought in the
    // money's currency, whose link is at the part's own rate — the share at the money's rate.
    var takenRub = AmountE4.zero
    for part in parts {
      let needed = need(part)
      let available = max(.zero, received - neededBefore)
      let take = min(needed, available)
      neededBefore += needed
      guard take.raw > 0 || needed.isZero else {
        model.stillOwed.append(
          OwedRemainder(partId: part.partId, remainingRubE4: part.remainingRubE4))
        continue
      }
      // A part the money reaches only partly takes all that is left of it: in rubles, what is
      // left of the rubles received, unless it was bought in the money's own currency.
      let restRub = receivedRub - takenRub
      let link =
        take == needed
        ? part.remainingRubE4
        : part.currency != currency && restRub > .zero
          ? min(restRub, part.remainingRubE4) : rubles(take, of: part)
      model.allocations.append(ReimbursementAllocation(partId: part.partId, amountE4: link))
      takenRub +=
        part.currency != currency
        ? link : inRubles ? take : MoneyDice.scaled(take, receivedRub, received)
      let rest = part.remainingRubE4 - link
      let foreign = part.currency != .rub || !inRubles
      if take == needed || rest <= drift(part.amountRubE4, foreign: foreign) {
        model.closes.append(part.partId)
      } else {
        model.stillOwed.append(OwedRemainder(partId: part.partId, remainingRubE4: rest))
      }
    }
    model.stillOwed += passedRemainders

    var over = max(.zero, received - neededBefore)
    // The rubles over are the rubles received less the rubles the parts took: every ruble that
    // came in is written once, a link or the surplus.
    let overRub = inRubles ? over : max(.zero, receivedRub - takenRub)
    // Money over is income however little, but for less than a kopeck: the rounding of shares.
    if over.raw > 0, overRub < AmountE4(raw: 100) {
      over = .zero
    }
    if over.raw > 0, !passed.isEmpty {
      return MoneyBackRuleModel(
        stillOwed: waiting.map {
          OwedRemainder(partId: $0.partId, remainingRubE4: $0.remainingRubE4)
        },
        skippedProvisional: passed.map(\.partId), refusal: .provisionalPartsOwed)
    }
    model.surplus = over
    model.surplusRub = over.isZero ? .zero : overRub
    return model
  }

  /// The plan the code makes, in the same shape.
  init(_ plan: MoneyBackPlan) {
    allocations = plan.allocations
    closes = plan.closes
    stillOwed = plan.stillOwed
    surplus = plan.surplus
    surplusRub = plan.surplusRub
    skippedProvisional = plan.skippedProvisional
    refusal = plan.refusal
  }

  init(
    allocations: [ReimbursementAllocation] = [], closes: [UUID] = [],
    stillOwed: [OwedRemainder] = [], surplus: AmountE4 = .zero, surplusRub: AmountE4 = .zero,
    skippedProvisional: [UUID] = [], refusal: MoneyBackRefusal? = nil
  ) {
    self.allocations = allocations
    self.closes = closes
    self.stillOwed = stillOwed
    self.surplus = surplus
    self.surplusRub = surplusRub
    self.skippedProvisional = skippedProvisional
    self.refusal = refusal
  }
}
