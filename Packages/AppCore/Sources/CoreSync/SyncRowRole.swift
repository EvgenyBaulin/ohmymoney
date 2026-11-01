import Foundation

/// Who wrote a row: the owner, or the app itself from other rows (a reconciliation difference,
/// interest, the surplus of money back, a fee, a tax). Both go into the journal alike — the
/// owner chose to keep everything —, and both are weighed by the same rules: two devices that
/// computed the same row the same way have nothing to choose between, two that computed it
/// differently (one was offline while the books under it changed) wait in the list of
/// conflicts like any other row, out of the sums until the owner chooses. The role only says
/// how the list words it.
public enum SyncRowRole: Hashable, Sendable {
  case owner
  case computed

  /// The prefixes of `external_id` of the operations and transfers the app writes itself.
  public static let computedPrefixes: [String] = [
    "reconcile:", "reimb:", "writeoff:", "transfer:", "ccinterest:", "debtinterest:",
    "debtmarkup:", "debtcost:", "instreturn:", "pledgeloss:", "npd:", "tax:", "alloc:",
  ]

  public static func of(table: String, fields: [String: SyncValue]) -> SyncRowRole {
    guard table == "transactions" || table == "transfers",
      case .string(let external)? = fields["external_id"]
    else { return .owner }
    return computedPrefixes.contains { external.hasPrefix($0) } ? .computed : .owner
  }
}
