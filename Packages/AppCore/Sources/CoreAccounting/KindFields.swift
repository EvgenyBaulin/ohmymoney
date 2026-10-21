import CoreKit
import Foundation

/// A field of an operation as the ↓ panel, the entry line, the save and a bulk change see it.
/// Every field maps to the column of the same name, with one exception: the person money came
/// back from (`fromPerson`) is the `for_person_id` of a reimbursement's part — where recording
/// money back and a repayment of a debt put the person, and what «от Ани» and the reports read.
public enum OperationField: String, CaseIterable, Sendable {
  /// The account the money moved on.
  case account
  /// What the account moved when it does not hold the operation's currency.
  case accountCharge
  case place
  case event
  case forWhom
  case forPerson
  case reimbursable
  case debtor
  /// Bought on credit or in instalments.
  case credit
  /// A payment on a debt.
  case debt
  case goal
  case category
  case quality
  /// Income only: the month the money is for.
  case periodMonth
  /// Income only: the expected income it arrived for.
  case expectedIncome
  /// A refund: the part of a purchase it takes back from.
  case refundOf
  /// Money back: whom it came from.
  case fromPerson
  case split
  case note
  /// The card that paid, a card of the operation's account. Money back names none: it is money
  /// from a person onto an account.
  case card
  /// Expense only: the cashback the owner typed for the purchase — an expectation, never income.
  case cashback
}

/// Which fields an operation of each kind has, and what becomes of the ones it does not.
///
/// * Income has no place, event, «на кого», person, «за другого» and no purchase on credit: it
///   is money that came in, not spending, and those cuts are about spending.
/// * A refund has everything a purchase has except credit and a payment on a debt: it brings
///   money back, it borrows and repays nothing. A refund of something bought for somebody else
///   keeps «за другого» together with the person who pays it back — a part «за другого» always
///   names that person.
/// * Money back is money from a person onto an account, and nothing else.
/// * A purchase, income and a refund may name the card that paid or took the money; money back
///   never does. Only a purchase has a cashback of its own.
///
/// The panel, the entry line, the save and a bulk change all ask this one table. What an
/// income stored before this rule existed — a place, an event, a person — stays in the
/// database: it is only hidden and ignored when read (`masked`).
public enum KindFields {
  private static let expense: Set<OperationField> = [
    .account, .accountCharge, .place, .event, .forWhom, .forPerson, .reimbursable, .debtor,
    .credit, .debt, .goal, .category, .quality, .split, .note, .card, .cashback,
  ]
  private static let income: Set<OperationField> = [
    .account, .accountCharge, .category, .periodMonth, .expectedIncome, .debt, .split, .note,
    .card,
  ]
  private static let refund: Set<OperationField> = [
    .account, .accountCharge, .place, .event, .forWhom, .forPerson, .reimbursable, .debtor,
    .goal, .category, .quality, .refundOf, .split, .note, .card,
  ]
  private static let reimbursement: Set<OperationField> = [
    .account, .accountCharge, .fromPerson, .debt, .note,
  ]

  public static func fields(of kind: TransactionKind) -> Set<OperationField> {
    switch kind {
    case .expense: expense
    case .income: income
    case .refund: refund
    case .reimbursement: reimbursement
    }
  }

  /// An operation whose parts all go to goals — a contribution, or taking money back out of a
  /// goal — moves no money between accounts: it keeps its account, but has nothing charged on
  /// it, so there is no «Списано со счёта», and no card money earns cashback on it.
  public static func fields(of kind: TransactionKind, goalOnly: Bool) -> Set<OperationField> {
    var fields = fields(of: kind)
    if goalOnly {
      fields.remove(.accountCharge)
      fields.remove(.cashback)
    }
    return fields
  }

  /// Every part of the draft goes to a goal: by the goal it names or by its category. Only a
  /// kind that has goals — a purchase, a refund — can be that: a goal named on income or on
  /// money back is a field the kind does not have, and the money still moves.
  public static func isGoalOnly(_ draft: TransactionDraft, tree: CategoryTree) -> Bool {
    fields(of: draft.kind).contains(.goal) && !draft.parts.isEmpty
      && draft.parts.allSatisfy {
        QualityResolver.isGoalContribution(
          goalId: $0.goalId, categoryId: $0.categoryId, categories: tree)
      }
  }

  /// The same for a saved operation.
  public static func isGoalOnly(_ entry: TransactionEntry, tree: CategoryTree) -> Bool {
    fields(of: entry.transaction.kind).contains(.goal) && !entry.parts.isEmpty
      && entry.parts.allSatisfy {
        QualityResolver.isGoalContribution(
          goalId: $0.goalId, categoryId: $0.categoryId, categories: tree)
      }
  }

  /// The draft with every field its kind does not have taken away, and the words of the line
  /// that had set those fields, to go to the note instead (an unknown name stays in the note
  /// the same way): «+5000 для мамы» is income of 5 000 with «для мамы» in its note.
  ///
  /// `words` are the words of the line by the field they set; only the words of a field taken
  /// away are returned, in the order of `OperationField`. A reimbursement keeps its person —
  /// the person the money came from — and its «на кого», which says nothing on its own.
  public static func stripped(
    _ draft: TransactionDraft, words: [OperationField: [String]] = [:],
    tree: CategoryTree = CategoryTree()
  ) -> (draft: TransactionDraft, toNote: [String]) {
    let kind = draft.kind
    let allowed = fields(of: kind, goalOnly: isGoalOnly(draft, tree: tree))
    var result = draft
    var removed: Set<OperationField> = []

    func drop(_ field: OperationField, when present: Bool, _ clear: () -> Void) {
      guard !allowed.contains(field), present else { return }
      clear()
      removed.insert(field)
    }

    drop(.accountCharge, when: result.accountCurrency != nil || result.accountAmount != nil) {
      result.accountCurrency = nil
      result.accountAmount = nil
    }
    drop(.place, when: result.placeId != nil) { result.placeId = nil }
    drop(.credit, when: result.creditDebtId != nil) { result.creditDebtId = nil }
    drop(.debt, when: result.debtId != nil) { result.debtId = nil }
    drop(.periodMonth, when: result.periodMonth != nil) { result.periodMonth = nil }
    drop(.card, when: result.cardId != nil) { result.cardId = nil }
    drop(.cashback, when: result.cashback != nil) { result.cashback = nil }

    let keepsPerson = kind == .reimbursement
    for index in result.parts.indices {
      drop(.event, when: result.parts[index].eventId != nil) {
        result.parts[index].eventId = nil
      }
      if !keepsPerson {
        drop(.forWhom, when: result.parts[index].forWhom != .me) {
          result.parts[index].forWhom = .me
        }
        drop(.forPerson, when: result.parts[index].forPersonId != nil) {
          result.parts[index].forPersonId = nil
        }
      }
      drop(.reimbursable, when: result.parts[index].reimbursable) {
        result.parts[index].reimbursable = false
        result.parts[index].reimbursementStatus = nil
      }
      drop(.debtor, when: result.parts[index].debtorPersonId != nil) {
        result.parts[index].debtorPersonId = nil
      }
      drop(.goal, when: result.parts[index].goalId != nil) {
        result.parts[index].goalId = nil
      }
      drop(.category, when: result.parts[index].categoryId != nil) {
        result.parts[index].categoryId = nil
      }
      drop(.quality, when: result.parts[index].quality != nil) {
        result.parts[index].quality = nil
        result.parts[index].qualitySource = nil
      }
      drop(.refundOf, when: result.parts[index].refundOfPartId != nil) {
        result.parts[index].refundOfPartId = nil
      }
    }

    // One part for a kind that is never split — after every part lost what the kind does not
    // have, so what the other parts named goes to the note too, not away with them.
    drop(.split, when: result.parts.count > 1) {
      var only = result.parts[0]
      only.amount = AmountE4.sum(result.parts.map(\.amount))
      only.amountExpression = nil
      result.parts = [only]
    }

    let toNote = OperationField.allCases.filter(removed.contains).flatMap { words[$0] ?? [] }
    return (result, toNote)
  }

  /// The operation as the rules read it: what its kind does not have is taken away, on the
  /// value only, never written back. Only income can carry such fields — they could be set on
  /// it before this rule existed — so income loses its place, event, «на кого», person,
  /// «за другого» and credit; every other kind comes back as stored.
  public static func masked(_ entry: TransactionEntry) -> TransactionEntry {
    guard entry.transaction.kind == .income else { return entry }
    var masked = entry
    masked.transaction.placeId = nil
    masked.transaction.creditDebtId = nil
    for index in masked.parts.indices {
      masked.parts[index].eventId = nil
      masked.parts[index].forWhom = .me
      masked.parts[index].forPersonId = nil
      masked.parts[index].debtorPersonId = nil
      masked.parts[index].reimbursable = false
      masked.parts[index].reimbursementStatus = nil
    }
    return masked
  }
}
