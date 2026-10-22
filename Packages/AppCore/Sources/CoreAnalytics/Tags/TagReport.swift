import CoreAccounting
import CoreKit
import Foundation

/// What one tag comes to.
public struct TagTotal: Hashable, Sendable, Identifiable {
  public var tagId: UUID
  /// My spending on the tagged parts, in rubles: the ledger's rule, refunds taken off.
  public var myRubE4: AmountE4
  /// Operations with at least one tagged part that counts.
  public var operations: Int
  public var parts: Int

  public var id: UUID { tagId }
}

/// Spending by tag. A part with two tags is in both rows — «операция с несколькими тегами входит
/// в каждый» (the owner, 22.10) — so the rows add up to more than the spending they cover;
/// `distinctRubE4` is that spending counted once, and `rowsOverlap` tells the screen to say so.
public struct TagReport: Hashable, Sendable {
  public var rows: [TagTotal]
  public var distinctRubE4: AmountE4
  public var sumOfRowsRubE4: AmountE4

  public var rowsOverlap: Bool { sumOfRowsRubE4 != distinctRubE4 }

  public static func compute(
    entries: [TransactionEntry], links: [PartTag], debts: [UUID: Debt] = [:]
  ) -> TagReport {
    var tagsOfPart: [UUID: [UUID]] = [:]
    for link in links { tagsOfPart[link.partId, default: []].append(link.tagId) }
    var amount: [UUID: AmountE4] = [:]
    var operations: [UUID: Set<UUID>] = [:]
    var partCount: [UUID: Int] = [:]
    var distinct = AmountE4.zero
    for entry in entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      let debt = transaction.debtId.flatMap { debts[$0] }
      let creditDebt = transaction.creditDebtId.flatMap { debts[$0] }
      for part in entry.parts {
        guard let tags = tagsOfPart[part.id] else { continue }
        let contribution = MyExpensesRule.contribution(
          part: part, in: transaction, debt: debt, creditDebt: creditDebt)
        guard !contribution.isZero else { continue }
        distinct += contribution
        for tagId in Set(tags) {
          amount[tagId, default: .zero] += contribution
          operations[tagId, default: []].insert(entry.id)
          partCount[tagId, default: 0] += 1
        }
      }
    }
    let rows = amount.map { tagId, total in
      TagTotal(
        tagId: tagId, myRubE4: total, operations: operations[tagId]?.count ?? 0,
        parts: partCount[tagId] ?? 0)
    }.sorted { left, right in
      if left.myRubE4 != right.myRubE4 { return left.myRubE4 > right.myRubE4 }
      return left.tagId.uuidString < right.tagId.uuidString
    }
    return TagReport(
      rows: rows, distinctRubE4: distinct, sumOfRowsRubE4: AmountE4.sum(rows.map(\.myRubE4)))
  }
}

/// The filter «по тегам»: operations with a part that carries the chosen tags.
public enum TagFilter {
  public enum Mode: Sendable { case any, all }

  /// The parts that carry any / all of `tagIds`. No tags chosen: every part passes.
  public static func partIds(
    among links: [PartTag], matching tagIds: Set<UUID>, mode: Mode
  ) -> Set<UUID>? {
    guard !tagIds.isEmpty else { return nil }
    var found: [UUID: Set<UUID>] = [:]
    for link in links where tagIds.contains(link.tagId) {
      found[link.partId, default: []].insert(link.tagId)
    }
    switch mode {
    case .any: return Set(found.keys)
    case .all: return Set(found.filter { $0.value == tagIds }.keys)
    }
  }

  public static func entries(
    _ entries: [TransactionEntry], links: [PartTag], matching tagIds: Set<UUID>, mode: Mode = .any
  ) -> [TransactionEntry] {
    guard let parts = partIds(among: links, matching: tagIds, mode: mode) else { return entries }
    return entries.filter { entry in entry.parts.contains { parts.contains($0.id) } }
  }
}
