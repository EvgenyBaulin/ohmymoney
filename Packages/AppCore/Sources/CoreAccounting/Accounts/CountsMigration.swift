import CoreKit
import Foundation

/// A compared count of a sheet of accounts written before the update, as the update reads it.
public struct MigratingCount: Hashable, Sendable {
  /// The operation the count points at (`transaction_id`): none, one alive, one in the bin.
  public enum Operation: Hashable, Sendable {
    case none, live, binned
  }

  public var id: UUID
  public var reconciliationId: UUID
  /// `nil` when the stored value does not read as a number: counted as not zero.
  public var differenceE4: AmountE4?
  public var operation: Operation

  public init(id: UUID, reconciliationId: UUID, differenceE4: AmountE4?, operation: Operation) {
    self.id = id
    self.reconciliationId = reconciliationId
    self.differenceE4 = differenceE4
    self.operation = operation
  }
}

/// Whether each compared count of a sheet written before the update records its difference
/// (`records_difference`). Nothing about it was stored, but the sheet left enough behind: it
/// wrote an operation for every row that differed when «Записать разницу» was chosen, none with
/// «Сохранить без записи», and none for a row at zero.
///
/// * Its own operation is alive → it records.
/// * Its own operation is in the bin → it keeps: the owner deleted the difference.
/// * No operation of its own: it records when a row of the same sheet has one, alive or in the
///   bin (the sheet was saved recording), or when every compared row of the sheet is at zero
///   (there was nothing to decline); it keeps otherwise.
///
/// A row in a currency without a rate had no operation even when its sheet recorded; the rows
/// around it tell. The rule changes no difference and writes no operation: it only says how
/// the count keeps what it has.
public enum CountsMigration {
  public static func recordsDifference(_ rows: [MigratingCount]) -> [UUID: Bool] {
    var sheetHasOperation: [UUID: Bool] = [:]
    var sheetAllAtZero: [UUID: Bool] = [:]
    for row in rows {
      if row.operation != .none { sheetHasOperation[row.reconciliationId] = true }
      let atZero = row.differenceE4?.isZero ?? false
      sheetAllAtZero[row.reconciliationId] =
        (sheetAllAtZero[row.reconciliationId] ?? true) && atZero
    }
    var modes: [UUID: Bool] = [:]
    for row in rows {
      switch row.operation {
      case .live:
        modes[row.id] = true
      case .binned:
        modes[row.id] = false
      case .none:
        modes[row.id] =
          sheetHasOperation[row.reconciliationId] ?? false
          || sheetAllAtZero[row.reconciliationId] ?? false
      }
    }
    return modes
  }
}
