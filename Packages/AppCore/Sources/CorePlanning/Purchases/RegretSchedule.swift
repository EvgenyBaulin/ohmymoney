import CoreAccounting
import CoreKit
import Foundation

/// A purchase the owner is asked about: «Не пожалели о покупке?».
public struct RegretQuestion: Hashable, Sendable, Identifiable {
  public var transactionId: UUID
  public var boughtOn: DateOnly
  /// The part that decided the question: the largest part that counts.
  public var categoryId: UUID?
  public var amountRubE4: AmountE4
  public var note: String?
  /// What names the purchase when it has no description: the place, else the category.
  public var placeName: String?
  public var categoryName: String?
  /// How many other questions wait behind this one; only one is put at a time.
  public var waitingMore: Int
  public var id: UUID { transactionId }

  public init(
    transactionId: UUID, boughtOn: DateOnly, categoryId: UUID?, amountRubE4: AmountE4,
    note: String?, placeName: String? = nil, categoryName: String? = nil, waitingMore: Int = 0
  ) {
    self.transactionId = transactionId
    self.boughtOn = boughtOn
    self.categoryId = categoryId
    self.amountRubE4 = amountRubE4
    self.note = note
    self.placeName = placeName
    self.categoryName = categoryName
    self.waitingMore = waitingMore
  }
}

/// What the owner answered about the purchases of one top-level category.
public struct RegretCategoryStat: Hashable, Sendable, Identifiable {
  /// `nil`: purchases without a category.
  public var categoryId: UUID?
  public var regretted: Int
  public var notRegretted: Int
  public var skipped: Int

  public init(categoryId: UUID?, regretted: Int, notRegretted: Int, skipped: Int) {
    self.categoryId = categoryId
    self.regretted = regretted
    self.notRegretted = notRegretted
    self.skipped = skipped
  }

  public var id: String { categoryId?.uuidString ?? "none" }
  /// The answers that tell something: «yes» and «no».
  public var answered: Int { regretted + notRegretted }
  /// The share of the answers that regret, in basis points; 0 without answers.
  public var regretShareBp: Int {
    answered == 0 ? 0 : (regretted * 10_000 + answered / 2) / answered
  }
}

/// «Не пожалели?»: which purchases to ask about and what the answers say.
public enum RegretSchedule {
  /// A purchase older than this is not asked about any more: a question asked weeks late is no
  /// help, and a first start must not flood the owner with old ones.
  public static let maxAgeDays = 14
  /// Only the newest question is put; the rest wait behind it, counted in its line.
  public static let maxQuestionsAtOnce = 1

  /// The purchases to ask about on `today`. A purchase is asked about when:
  /// it is a live expense of my own, not a line the app wrote for its books; the part that counts
  /// (not paid for somebody else, not a goal contribution, not a system category, not in a
  /// category marked as an essential expense) is above `thresholdRubE4` — see
  /// `PurchasePause.threshold` —; it has no answer and was not asked yet; and
  /// `settings.regretAskAfterDays` have passed since it, but no more than `maxAgeDays`, and it
  /// was made on or after the day the question was turned on. The newest question first. With
  /// the setting off, or no threshold, nothing is asked. `places` name a purchase without a
  /// description.
  public static func due(
    entries: [TransactionEntry], tree: CategoryTree, settings: PurchaseSettings,
    thresholdRubE4: AmountE4?, today: DateOnly, calendar: CalendarContext, places: [Place] = []
  ) -> [RegretQuestion] {
    guard settings.regretEnabled, let threshold = thresholdRubE4 else { return [] }
    let placeNames = Dictionary(places.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    var found: [RegretQuestion] = []
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense, transaction.regret == nil,
        transaction.regretAskedOn == nil, transaction.debtId == nil,
        OperationLink(externalId: transaction.externalId) == nil
      else { continue }
      let counted = entry.parts.filter { part in
        !part.reimbursable && part.goalId == nil && tree.systemRole(of: part.categoryId) == nil
          && !tree.isEssential(part.categoryId)
      }
      let sum = AmountE4.sum(counted.map(\.amountRubE4))
      guard !counted.isEmpty, sum > threshold else { continue }
      let day = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      let age = day.days(to: today)
      guard age >= settings.regretAskAfterDays, age <= maxAgeDays else { continue }
      if let since = settings.regretEnabledOn, day < since { continue }
      let main = counted.max { $0.amountRubE4 < $1.amountRubE4 }
      let placeName = transaction.placeId.flatMap { placeNames[$0] }
      found.append(
        RegretQuestion(
          transactionId: transaction.id, boughtOn: day, categoryId: main?.categoryId,
          amountRubE4: sum, note: transaction.note,
          placeName: placeName.flatMap { $0.isEmpty ? nil : $0 },
          categoryName: tree.category(main?.categoryId)?.name))
    }
    return found.sorted { left, right in
      if left.boughtOn != right.boughtOn { return left.boughtOn > right.boughtOn }
      return left.transactionId.uuidString < right.transactionId.uuidString
    }
  }

  /// The answers by top-level category: the category with the highest share of regret first, then
  /// the one with more answers.
  public static func statistics(
    entries: [TransactionEntry], tree: CategoryTree
  ) -> [RegretCategoryStat] {
    var byCategory: [UUID?: RegretCategoryStat] = [:]
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, let answer = transaction.regret else { continue }
      let main = entry.parts.max { $0.amountRubE4 < $1.amountRubE4 }
      let root = tree.root(of: main?.categoryId)?.id ?? main?.categoryId
      var stat =
        byCategory[root]
        ?? RegretCategoryStat(categoryId: root, regretted: 0, notRegretted: 0, skipped: 0)
      switch answer {
      case .yes: stat.regretted += 1
      case .no: stat.notRegretted += 1
      case .skip: stat.skipped += 1
      }
      byCategory[root] = stat
    }
    return byCategory.values.sorted { left, right in
      if left.regretShareBp != right.regretShareBp {
        return left.regretShareBp > right.regretShareBp
      }
      if left.answered != right.answered { return left.answered > right.answered }
      return left.id < right.id
    }
  }

  /// The edit that records the answer on an operation: the answer and the day it was put.
  /// `.skip` is also what «Не спрашивать» writes, so the question is not put again.
  public static func recording(
    _ answer: PurchaseRegret, on transaction: Transaction, today: DateOnly
  ) -> Transaction {
    var copy = transaction
    copy.regret = answer
    copy.regretAskedOn = today
    return copy
  }
}
