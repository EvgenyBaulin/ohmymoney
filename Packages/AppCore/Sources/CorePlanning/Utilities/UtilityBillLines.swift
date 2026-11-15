import CoreKit
import Foundation

/// Editing the lines of a bill: a line is changed, added or removed and the total of the bill
/// follows the lines. A bill without lines keeps the total it was typed with.
public enum UtilityBillLines {
  /// A line as the form holds it before it is saved. `id` is that of the stored line, or new.
  public struct Draft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var service: String
    public var amountE4: AmountE4
    /// What the meter showed or used for the line, when the owner gives it.
    public var quantityE4: AmountE4?
    public var tariffE4: AmountE4?
    public var meterId: UUID?

    public init(
      id: UUID = UUID(), service: String = "", amountE4: AmountE4 = .zero,
      quantityE4: AmountE4? = nil, tariffE4: AmountE4? = nil, meterId: UUID? = nil
    ) {
      self.id = id
      self.service = service
      self.amountE4 = amountE4
      self.quantityE4 = quantityE4
      self.tariffE4 = tariffE4
      self.meterId = meterId
    }

    public init(_ charge: UtilityCharge) {
      self.init(
        id: charge.id, service: charge.service, amountE4: charge.amountE4,
        quantityE4: charge.quantityE4, tariffE4: charge.tariffE4, meterId: charge.meterId)
    }

    /// A line without a service name is not written.
    public var isBlank: Bool {
      service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// What one save of the form writes: the bill, the lines to write over or add, the lines to
  /// delete. All of it goes in one change, so ⌘Z takes it back in one step.
  public struct Edit: Hashable, Sendable {
    public var bill: UtilityBill
    public var charges: [UtilityCharge]
    public var deletedChargeIDs: [UUID]
  }

  /// The lines of a bill in the order the owner sees them.
  public static func lines(of bill: UtilityBill, in charges: [UtilityCharge]) -> [Draft] {
    charges.filter { $0.billId == bill.id }
      .sorted { ($0.sort, $0.id.uuidString) < ($1.sort, $1.id.uuidString) }
      .map(Draft.init)
  }

  /// The sum of the lines that will be written; a recalculation below zero lowers it.
  public static func total(of drafts: [Draft]) -> AmountE4 {
    AmountE4.sum(drafts.filter { !$0.isBlank }.map(\.amountE4))
  }

  /// `bill` with the total of the written lines (kept as typed when there are none), the lines
  /// numbered in order, and the stored lines of the bill that the drafts no longer hold.
  public static func edit(
    bill: UtilityBill, drafts: [Draft], stored: [UtilityCharge]
  ) -> Edit {
    let kept = drafts.filter { !$0.isBlank }
    var result = bill
    if !kept.isEmpty { result.totalE4 = total(of: kept) }
    let charges = kept.enumerated().map { index, draft in
      UtilityCharge(
        id: draft.id, billId: bill.id,
        service: draft.service.trimmingCharacters(in: .whitespacesAndNewlines),
        amountE4: draft.amountE4, quantityE4: draft.quantityE4, tariffE4: draft.tariffE4,
        meterId: draft.meterId, sort: index)
    }
    let keptIDs = Set(kept.map(\.id))
    let gone = stored.filter { $0.billId == bill.id && !keptIDs.contains($0.id) }.map(\.id)
    return Edit(bill: result, charges: charges, deletedChargeIDs: gone)
  }
}
