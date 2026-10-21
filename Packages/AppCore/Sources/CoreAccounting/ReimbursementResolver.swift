import CoreKit
import Foundation

/// How much of a reimbursement goes to one part I paid for somebody else.
public struct ReimbursementAllocation: Hashable, Sendable {
  public var partId: UUID
  public var amountE4: AmountE4

  public init(partId: UUID, amountE4: AmountE4) {
    self.partId = partId
    self.amountE4 = amountE4
  }
}

/// Money that came back on top of what I paid. It is the only part of a reimbursement
/// that is income, and it always lands in the system Surcharges category — in the currency the
/// money came in, on the account it came onto.
public struct SurchargeIncome: Hashable, Sendable {
  /// In `currency`, the currency of the money back.
  public var amountE4: AmountE4
  public var currency: CurrencyCode
  /// The same money in rubles, at the rate of the money back.
  public var amountRubE4: AmountE4
  /// The account the money back came onto; `nil` — the main account.
  public var accountId: UUID?

  public init(
    amountE4: AmountE4, currency: CurrencyCode = .rub, amountRubE4: AmountE4? = nil,
    accountId: UUID? = nil
  ) {
    self.amountE4 = amountE4
    self.currency = currency
    self.amountRubE4 = amountRubE4 ?? amountE4
    self.accountId = accountId
  }

  public var systemRole: SystemRole { .surcharges }
}

/// A part that was closed for less money than I paid: the difference becomes my expense,
/// in the category of the original part.
public struct ShortfallExpense: Hashable, Sendable {
  public var partId: UUID
  public var transactionId: UUID
  public var categoryId: UUID?
  public var forWhom: ForWhom
  public var amountE4: AmountE4
  /// The account the purchase was paid from: the money that did not come back left it.
  public var accountId: UUID?

  public init(
    partId: UUID, transactionId: UUID, categoryId: UUID?, forWhom: ForWhom,
    amountE4: AmountE4, accountId: UUID? = nil
  ) {
    self.partId = partId
    self.transactionId = transactionId
    self.categoryId = categoryId
    self.forWhom = forWhom
    self.amountE4 = amountE4
    self.accountId = accountId
  }
}

/// Everything one reimbursement asks the storage layer to write. The resolver decides;
/// the repository applies. Nothing here touches the database itself.
///
/// The four pieces, in the order the UI shows them:
///
/// * `allocations` — how the money was split between the selected parts, oldest first.
///   This is what the «edit the distribution» sheet renders and hands back.
/// * `links` — one `reimbursement_links` row per closed part, including a part that
///   received nothing, so the closure stays traceable.
/// * `closedPartIds` — the parts whose `reimbursement_status` becomes `returned`.
/// * `surplus` / `shortfalls` — the extra operations to record. At most one surplus
///   (income in Surcharges) and one shortfall expense per underpaid part. The automatic
///   distribution produces one or the other, never both: it only leaves money over once
///   every part is covered. A hand-corrected one can produce both — money left aside on
///   purpose is a surplus, and the parts it did not reach are still closed short.
public struct ReimbursementOutcome: Hashable, Sendable {
  public var reimbursementTxId: UUID
  public var allocations: [ReimbursementAllocation]
  public var links: [ReimbursementLink]
  public var closedPartIds: [UUID]
  public var surplus: SurchargeIncome?
  public var shortfalls: [ShortfallExpense]

  public init(
    reimbursementTxId: UUID,
    allocations: [ReimbursementAllocation],
    links: [ReimbursementLink],
    closedPartIds: [UUID],
    surplus: SurchargeIncome? = nil,
    shortfalls: [ShortfallExpense] = []
  ) {
    self.reimbursementTxId = reimbursementTxId
    self.allocations = allocations
    self.links = links
    self.closedPartIds = closedPartIds
    self.surplus = surplus
    self.shortfalls = shortfalls
  }

  /// Money that actually reached the parts.
  public var allocatedE4: AmountE4 {
    AmountE4.sum(allocations.map(\.amountE4))
  }

  public var surplusE4: AmountE4 { surplus?.amountE4 ?? .zero }

  public var shortfallTotalE4: AmountE4 {
    AmountE4.sum(shortfalls.map(\.amountE4))
  }

  /// The reimbursement itself, `allocatedE4 + surplusE4`. None of it is income except the
  /// surplus, and none of it is spending.
  public var receivedE4: AmountE4 { allocatedE4 + surplusE4 }
}

public enum ReimbursementError: Error, Equatable, Sendable, CustomStringConvertible {
  case noPartsSelected
  case negativeAmount
  case duplicatePart(UUID)
  case unknownPart(UUID)
  case negativeAllocation(UUID)
  /// One part was given more than I paid for it. Extra money is a surplus, not a bonus
  /// on a single part.
  case allocationExceedsPart(UUID)
  /// The distribution adds up to more than the person actually returned.
  case allocationExceedsAmount
  /// The operation of this part still converts at a provisional rate. The rubles a link
  /// fixes now would drift away from the refined ones, so the part waits for the pipeline.
  case provisionalRate(UUID)
  /// The part stopped waiting while the reimbursement was being recorded: its purchase was
  /// deleted or taken back by ⌘Z, or the part was written off or closed by another
  /// reimbursement. The storage layer refuses the whole reimbursement, and nothing is written.
  case partNoLongerOwed(UUID)
  /// «Списать остаток» on a part no money came back for yet: there is no remainder, the whole
  /// part is written off instead.
  case nothingReturnedYet(UUID)
  /// Writing a whole part off when some money already came back for it: only what is left of
  /// it is written off («Списать остаток»).
  case partlyReturned(UUID)

  public var description: String {
    switch self {
    case .noPartsSelected: return "A reimbursement has to close at least one part."
    case .negativeAmount: return "A reimbursement cannot be negative."
    case .duplicatePart: return "The same part was selected twice."
    case .unknownPart: return "The distribution names a part that was not selected."
    case .negativeAllocation: return "A part cannot be given a negative share."
    case .allocationExceedsPart: return "A part cannot be given more than I paid for it."
    case .allocationExceedsAmount: return "The distribution is larger than the money returned."
    case .provisionalRate: return "The rate of this part is still provisional."
    case .partNoLongerOwed: return "The part is no longer waiting for its money."
    case .nothingReturnedYet: return "Nothing came back for this part yet."
    case .partlyReturned: return "Some of the money came back for this part already."
    }
  }
}

/// Closing the parts I paid for other people.
///
/// A `reimbursement` operation is not income: it closes the parts it is linked to. The
/// money is spread over the selected parts from the oldest to the newest, and the result
/// can be corrected by hand — so the resolver both produces a distribution and accepts
/// one. Whatever is left over is income in Surcharges; whatever is missing when the parts
/// are closed anyway becomes my expense in the category of the original part.
///
/// The parts and the reimbursement must be in the same currency; converting is the
/// caller's job, as it is everywhere else in the core. In the app that currency is always
/// rubles (`OwedPart.inRubles`), so `reimbursement_links.amount_e4` holds rubles too. A
/// part whose operation still converts at a provisional rate is refused: the rubles a link
/// fixed today would no longer match the part once the rate is refined.
public enum ReimbursementResolver {

  /// Spreads the returned money over the parts, oldest first. Parts that the money did
  /// not reach are still listed, with a zero share, so the UI can show them.
  public static func allocate(
    amountE4: AmountE4, over parts: [OwedPart]
  ) -> [ReimbursementAllocation] {
    var left = max(amountE4, .zero)
    var result: [ReimbursementAllocation] = []
    result.reserveCapacity(parts.count)
    for part in parts.sorted(by: MyExpensesRule.oldestFirst) {
      let share = min(left, max(part.amountE4, .zero))
      result.append(ReimbursementAllocation(partId: part.partId, amountE4: share))
      left = left - share
    }
    return result
  }

  /// Turns a reimbursement into the records to write.
  ///
  /// `allocation` is the hand-corrected distribution; when it is `nil` the automatic one
  /// is used. Every selected part is closed, even one that received nothing: selecting it
  /// is the decision to settle it, and the missing money is recorded as my expense.
  ///
  /// `makeId` exists so the outcome can be reproduced in tests; it defaults to fresh
  /// UUIDs.
  ///
  /// The surplus lands on `accountId`, the account the money back came onto; a shortfall is
  /// spending from the account the purchase was paid from (`OwedPart.accountId`).
  public static func resolve(
    reimbursementTxId: UUID,
    amountE4: AmountE4,
    closing parts: [OwedPart],
    allocation: [ReimbursementAllocation]? = nil,
    accountId: UUID? = nil,
    makeId: () -> UUID = { UUID() }
  ) throws -> ReimbursementOutcome {
    guard !parts.isEmpty else { throw ReimbursementError.noPartsSelected }
    guard !amountE4.isNegative else { throw ReimbursementError.negativeAmount }

    var byId: [UUID: OwedPart] = [:]
    for part in parts {
      guard byId.updateValue(part, forKey: part.partId) == nil else {
        throw ReimbursementError.duplicatePart(part.partId)
      }
      guard !part.rateProvisional else {
        throw ReimbursementError.provisionalRate(part.partId)
      }
    }

    let ordered = parts.sorted(by: MyExpensesRule.oldestFirst)
    let allocations = try normalize(
      allocation ?? allocate(amountE4: amountE4, over: ordered),
      ordered: ordered, byId: byId, amountE4: amountE4)

    var links: [ReimbursementLink] = []
    var shortfalls: [ShortfallExpense] = []
    links.reserveCapacity(allocations.count)
    for allocated in allocations {
      guard let part = byId[allocated.partId] else { continue }
      links.append(
        ReimbursementLink(
          id: makeId(), reimbursementTxId: reimbursementTxId, partId: part.partId,
          amountE4: allocated.amountE4))
      let missing = part.amountE4 - allocated.amountE4
      if missing.raw > 0 {
        shortfalls.append(
          ShortfallExpense(
            partId: part.partId, transactionId: part.transactionId,
            categoryId: part.categoryId, forWhom: part.forWhom, amountE4: missing,
            accountId: part.accountId))
      }
    }

    let allocated = AmountE4.sum(allocations.map(\.amountE4))
    let left = amountE4 - allocated
    let surplus = left.raw > 0 ? SurchargeIncome(amountE4: left, accountId: accountId) : nil

    return ReimbursementOutcome(
      reimbursementTxId: reimbursementTxId,
      allocations: allocations,
      links: links,
      closedPartIds: allocations.map(\.partId),
      surplus: surplus,
      shortfalls: shortfalls)
  }

  /// Validates a hand-made distribution and puts it back into «oldest first» order, with
  /// a zero share for any selected part the caller left out.
  private static func normalize(
    _ allocation: [ReimbursementAllocation],
    ordered: [OwedPart],
    byId: [UUID: OwedPart],
    amountE4: AmountE4
  ) throws -> [ReimbursementAllocation] {
    var shares: [UUID: AmountE4] = [:]
    for entry in allocation {
      guard let part = byId[entry.partId] else {
        throw ReimbursementError.unknownPart(entry.partId)
      }
      guard !entry.amountE4.isNegative else {
        throw ReimbursementError.negativeAllocation(entry.partId)
      }
      guard entry.amountE4 <= part.amountE4 else {
        throw ReimbursementError.allocationExceedsPart(entry.partId)
      }
      guard shares.updateValue(entry.amountE4, forKey: entry.partId) == nil else {
        throw ReimbursementError.duplicatePart(entry.partId)
      }
    }
    guard AmountE4.sum(shares.values) <= amountE4 else {
      throw ReimbursementError.allocationExceedsAmount
    }
    return ordered.map {
      ReimbursementAllocation(partId: $0.partId, amountE4: shares[$0.partId] ?? .zero)
    }
  }
}

/// The key a surplus or a shortfall keeps in `external_id`, pointing back at the
/// reimbursement that produced it. Deleting the reimbursement finds them by it and takes them
/// along, and undoing the deletion brings them back; the schema already has a unique index on
/// that column, so no migration was needed. Ids are written in lower case, so the prefix of
/// one reimbursement never depends on how a UUID prints.
public enum ReimbursementCompanions {
  /// Everything a reimbursement produced starts with this.
  public static func keyPrefix(of reimbursementId: UUID) -> String {
    "reimb:\(reimbursementId.uuidString.lowercased()):"
  }

  public static func surplusKey(of reimbursementId: UUID) -> String {
    keyPrefix(of: reimbursementId) + "surplus"
  }

  public static func shortfallKey(of reimbursementId: UUID, partId: UUID) -> String {
    keyPrefix(of: reimbursementId) + "shortfall:" + partId.uuidString.lowercased()
  }
}
