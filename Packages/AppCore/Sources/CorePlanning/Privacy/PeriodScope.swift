import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The data cut to a span of days, for a copy «за период».
///
/// What has a date is cut: operations (the day they are shown on, in the zone they were
/// recorded in), transfers, reconciliations, expected incomes that fall on one day, the journal
/// of debts, the notes of days, the valuations of assets, the prices of wishes. What is a
/// reference book (people, places, accounts, categories, debts, goals …), a plan with no single
/// day (scheduled payments, rules, limits) or a setting stays whole.
///
/// A return or a repayment must not be left without what it returns: an operation outside the
/// span that a kept operation points at (`refundOfPartId`, a link of a reimbursement) is pulled
/// in by default and listed in `pulledIn`, so the copy never holds a refund of a purchase it
/// does not have. With `pullIn: false` the operation is left out and the dangling reference is
/// cleared, and the id of the kept operation is listed in `unresolved`.
public enum PeriodScope {
  public struct Result: Sendable {
    public var dataset: Dataset
    /// Operations from outside the span that were kept because a kept one points at them.
    public var pulledIn: [UUID]
    /// Kept operations that point at something outside the span that was not kept.
    public var unresolved: [UUID]
  }

  /// The day an operation is shown on.
  static func day(of transaction: Transaction) -> DateOnly {
    TravelDay.day(of: transaction.occurredAt, zoneId: transaction.timeZoneId)
  }

  public static func apply(
    _ range: DayRange, to dataset: Dataset, pullIn: Bool = true
  ) -> Dataset {
    scope(range, of: dataset, pullIn: pullIn).dataset
  }

  public static func scope(
    _ range: DayRange, of dataset: Dataset, pullIn: Bool = true
  ) -> Result {
    var d = dataset
    var keep = Set(
      dataset.entries.filter { range.contains(day(of: $0.transaction)) }.map(\.id))

    // Follow the pointers out of the span until nothing new is added.
    var partOwner: [UUID: UUID] = [:]
    for entry in dataset.entries {
      for part in entry.parts { partOwner[part.id] = entry.id }
    }
    let outgoing = pointers(in: dataset, partOwner: partOwner)
    var pulled: [UUID] = []
    var unresolved = Set<UUID>()
    if pullIn {
      var queue = Array(keep)
      while let id = queue.popLast() {
        for target in outgoing[id] ?? [] where !keep.contains(target) {
          keep.insert(target)
          pulled.append(target)
          queue.append(target)
        }
      }
    } else {
      for id in keep {
        if (outgoing[id] ?? []).contains(where: { !keep.contains($0) }) {
          unresolved.insert(id)
        }
      }
    }

    d.entries = dataset.entries.filter { keep.contains($0.id) }
    if !pullIn {
      let keptParts = Set(d.entries.flatMap { $0.parts.map(\.id) })
      for index in d.entries.indices {
        for part in d.entries[index].parts.indices {
          if let origin = d.entries[index].parts[part].refundOfPartId,
            !keptParts.contains(origin)
          {
            d.entries[index].parts[part].refundOfPartId = nil
          }
        }
      }
    }
    let keptParts = Set(d.entries.flatMap { $0.parts.map(\.id) })
    d.links = dataset.links.filter {
      keep.contains($0.reimbursementTxId) && keptParts.contains($0.partId)
    }
    d.tagBook.links = dataset.tagBook.links.filter { keptParts.contains($0.partId) }
    d.feedback = dataset.feedback.filter { $0.partId.map(keptParts.contains) ?? true }

    d.transfers = dataset.transfers.filter {
      range.contains(TravelDay.day(of: $0.occurredAt, zoneId: nil))
    }
    d.dayNotes = dataset.dayNotes.filter { range.contains($0.day) }
    d.assetValuations = dataset.assetValuations.filter { range.contains($0.day) }

    var planning = dataset.planning
    planning.expected = dataset.planning.expected.filter { income in
      guard income.freq == nil, let due = income.dueDate else { return true }
      return range.contains(due)
    }
    let expectedIds = Set(planning.expected.map(\.id))
    planning.expectedLinks = dataset.planning.expectedLinks.filter {
      expectedIds.contains($0.expectedIncomeId) && keep.contains($0.transactionId)
    }
    planning.reconciliations = dataset.planning.reconciliations.filter {
      range.contains($0.date)
    }
    let reconciliationIds = Set(planning.reconciliations.map(\.id))
    planning.reconciledBalances = dataset.planning.reconciledBalances.filter {
      reconciliationIds.contains($0.reconciliationId)
    }
    planning.debtEntries = dataset.planning.debtEntries.filter { entry in
      if let date = entry.date { return range.contains(date) }
      if let at = entry.occurredAt {
        return range.contains(TravelDay.day(of: at, zoneId: nil))
      }
      return true
    }
    d.planning = planning
    d.wishPrices = dataset.wishPrices.filter { range.contains($0.onDate) }

    d.version &+= 1
    return Result(dataset: d, pulledIn: pulled, unresolved: unresolved.sorted { $0.uuidString < $1.uuidString })
  }

  /// For every operation, the other operations it points at: the owners of the parts it
  /// refunds and of the parts a reimbursement pays back.
  private static func pointers(
    in dataset: Dataset, partOwner: [UUID: UUID]
  ) -> [UUID: [UUID]] {
    var result: [UUID: [UUID]] = [:]
    for entry in dataset.entries {
      for part in entry.parts {
        if let origin = part.refundOfPartId, let owner = partOwner[origin], owner != entry.id {
          result[entry.id, default: []].append(owner)
        }
      }
    }
    for link in dataset.links {
      if let owner = partOwner[link.partId], owner != link.reimbursementTxId {
        result[link.reimbursementTxId, default: []].append(owner)
      }
    }
    return result
  }
}
