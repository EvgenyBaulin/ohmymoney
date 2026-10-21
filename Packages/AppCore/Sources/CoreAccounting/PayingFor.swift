import CoreKit
import Foundation

/// «За кого» of the ↓ panel: whom an expense was paid for, in the four ways people say it, and
/// what each makes of the operation's parts with the mechanism there already is — a part paid
/// for somebody (`reimbursable`, its debtor) is owed to me until money comes back; a gift is a
/// part «на кого» that person (`forPersonId`) and owes nothing. No model of its own: the parts are
/// the truth, and `reading(of:)` reads the choice back from them.
public enum PayingFor: Hashable, Sendable {
  /// Себе: one part, mine.
  case me
  /// За другого: one part for `person` — owed back (`paysBack`) or a gift.
  case somebody(UUID, paysBack: Bool)
  /// Пополам: my half and `person`'s, which is owed back.
  case half(UUID)
  /// Поровну: my share and one equal share owed back by each of `people`.
  case evenly([UUID])

  /// How many people share the bill, me included.
  public var shareCount: Int {
    switch self {
    case .me, .somebody: 1
    case .half: 2
    case .evenly(let people): people.count + 1
    }
  }
}

/// What a choice of «За кого» comes to, in money: what I paid, what is mine and what each person
/// owes — the sentence under the fields says it in words.
public struct PayingForOutcome: Hashable, Sendable {
  public var paid: AmountE4
  public var mine: AmountE4
  public var owed: [(person: UUID, amount: AmountE4)]
  /// Paid for somebody as a gift: nobody owes anything, and it is not mine either.
  public var giftFor: UUID?

  public static func == (left: Self, right: Self) -> Bool {
    left.paid == right.paid && left.mine == right.mine && left.giftFor == right.giftFor
      && left.owed.map(\.person) == right.owed.map(\.person)
      && left.owed.map(\.amount) == right.owed.map(\.amount)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(paid)
    hasher.combine(mine)
    hasher.combine(giftFor)
    for entry in owed {
      hasher.combine(entry.person)
      hasher.combine(entry.amount)
    }
  }
}

public enum PayingForRules {
  /// The draft with its parts laid out for `choice`. The first part is the template: its
  /// category, quality, event, note and goal go to every part, and it stays the first — my share
  /// where there is one. The shares are equal and add up to the total to the last unit
  /// (`AmountE4.split`), the extra units going to my share. Nothing changes for a draft that
  /// cannot be paid for somebody: not an expense, a refund of a purchase, money for a goal.
  public static func laying(_ choice: PayingFor, on draft: TransactionDraft) -> TransactionDraft {
    guard draft.kind == .expense, var template = draft.parts.first,
      template.refundOfPartId == nil, template.goalId == nil
    else { return draft }
    template.amountExpression = nil
    template.reimbursable = false
    template.debtorPersonId = nil
    template.reimbursementStatus = nil
    var result = draft
    switch choice {
    case .me:
      template.amount = draft.amount
      if template.forPersonId != nil, template.forWhom == .other {
        template.forPersonId = nil
        template.forWhom = .me
      }
      result.parts = [template]
    case .somebody(let person, let paysBack):
      template.amount = draft.amount
      if paysBack {
        template.reimbursable = true
        template.debtorPersonId = person
      } else {
        template.forWhom = .other
        template.forPersonId = person
      }
      result.parts = [template]
    case .half(let person):
      result.parts = shares(of: draft.amount, template: template, owedBy: [person])
    case .evenly(let people):
      result.parts = shares(of: draft.amount, template: template, owedBy: people)
    }
    return result
  }

  private static func shares(
    of total: AmountE4, template: PartDraft, owedBy people: [UUID]
  ) -> [PartDraft] {
    let amounts = total.split(into: people.count + 1)
    var mine = template
    mine.amount = amounts[0]
    var parts = [mine]
    for (index, person) in people.enumerated() {
      var owed = template
      owed.id = UUID()
      owed.amount = amounts[index + 1]
      owed.reimbursable = true
      owed.debtorPersonId = person
      parts.append(owed)
    }
    return parts
  }

  /// The choice the parts of a draft say, when they say one of the four: nil for parts laid out
  /// any other way (a split by categories, shares that are not equal), which the panel then
  /// leaves to the parts editor.
  public static func reading(of draft: TransactionDraft) -> PayingFor? {
    let parts = draft.parts
    guard let first = parts.first else { return nil }
    if parts.count == 1 {
      if first.reimbursable, let person = first.debtorPersonId {
        return .somebody(person, paysBack: true)
      }
      if !first.reimbursable, first.forWhom == .other, let person = first.forPersonId {
        return .somebody(person, paysBack: false)
      }
      return first.reimbursable ? nil : .me
    }
    let rest = parts.dropFirst()
    guard !first.reimbursable,
      rest.allSatisfy({ $0.reimbursable && $0.debtorPersonId != nil }),
      parts.map(\.amount) == draft.amount.split(into: parts.count),
      rest.allSatisfy({ $0.categoryId == first.categoryId })
    else { return nil }
    let people = rest.compactMap(\.debtorPersonId)
    return people.count == 1 ? .half(people[0]) : .evenly(people)
  }

  /// What the choice comes to for `total`.
  public static func outcome(of choice: PayingFor, total: AmountE4) -> PayingForOutcome {
    switch choice {
    case .me:
      return PayingForOutcome(paid: total, mine: total, owed: [], giftFor: nil)
    case .somebody(let person, let paysBack):
      return paysBack
        ? PayingForOutcome(paid: total, mine: .zero, owed: [(person, total)], giftFor: nil)
        : PayingForOutcome(paid: total, mine: .zero, owed: [], giftFor: person)
    case .half(let person):
      let amounts = total.split(into: 2)
      return PayingForOutcome(paid: total, mine: amounts[0], owed: [(person, amounts[1])])
    case .evenly(let people):
      let amounts = total.split(into: people.count + 1)
      return PayingForOutcome(
        paid: total, mine: amounts[0],
        owed: people.enumerated().map { ($0.element, amounts[$0.offset + 1]) })
    }
  }
}
