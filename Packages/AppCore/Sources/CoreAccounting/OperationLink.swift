import CoreKit
import Foundation

/// What an operation the app wrote by itself points back at, through
/// `transactions.external_id`:
///
/// * `reimb:<reimbursement>:surplus` — the surplus of a reimbursement, an income in
///   Surcharges;
/// * `reimb:<reimbursement>:shortfall:<part>` — a shortfall, my expense;
/// * `sched:<payment>:<due date>` — «Mark as paid» of a scheduled payment for that due date;
/// * `reconcile:<reconciliation>` — the difference a reconciliation of one total recorded, in
///   the category the app keeps for it, «Сверка»;
/// * `reconcile:<reconciliation>:<balance>` — the difference of one counted balance of an
///   account (`ReconciledBalance`), in that balance's currency;
/// * `transfer:<transfer>:fee` — the fee of a transfer, an ordinary expense;
/// * `writeoff:<part>:<operation>` — what is left of a part paid for somebody else, written
///   off after only some of it came back.
///
/// Ids are kept as they are written (lowercased UUIDs in the app, short numbers in the
/// golden fixture), so a reimbursement and a write-off are compared by text.
public enum OperationLink: Hashable, Sendable {
  case surplus(reimbursement: String)
  case shortfall(reimbursement: String, part: String)
  case scheduled(paymentId: UUID, due: DateOnly)
  case reconciliation(UUID)
  case reconciledBalance(reconciliation: UUID, balance: UUID)
  case transferFee(UUID)
  case remainderWriteOff(part: String, operation: String)

  public init?(externalId: String?) {
    guard let externalId else { return nil }
    let fields = externalId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    switch fields.first {
    case "reimb" where fields.count == 3 && fields[2] == "surplus":
      self = .surplus(reimbursement: fields[1])
    case "reimb" where fields.count == 4 && fields[2] == "shortfall":
      self = .shortfall(reimbursement: fields[1], part: fields[3])
    case "sched" where fields.count == 3:
      guard let id = UUID(uuidString: fields[1]), let due = DateOnly(iso: fields[2]) else {
        return nil
      }
      self = .scheduled(paymentId: id, due: due)
    case "reconcile" where fields.count == 2:
      guard let id = UUID(uuidString: fields[1]) else { return nil }
      self = .reconciliation(id)
    case "reconcile" where fields.count == 3:
      guard let id = UUID(uuidString: fields[1]), let balance = UUID(uuidString: fields[2]) else {
        return nil
      }
      self = .reconciledBalance(reconciliation: id, balance: balance)
    case "transfer" where fields.count == 3 && fields[2] == "fee":
      guard let id = UUID(uuidString: fields[1]) else { return nil }
      self = .transferFee(id)
    case "writeoff" where fields.count == 3 && !fields[1].isEmpty && !fields[2].isEmpty:
      self = .remainderWriteOff(part: fields[1], operation: fields[2])
    default:
      return nil
    }
  }

  public var externalId: String {
    switch self {
    case .surplus(let reimbursement): "reimb:\(reimbursement):surplus"
    case .shortfall(let reimbursement, let part): "reimb:\(reimbursement):shortfall:\(part)"
    case .scheduled(let paymentId, let due): "sched:\(paymentId.uuidString.lowercased()):\(due.iso)"
    case .reconciliation(let id): "reconcile:\(id.uuidString.lowercased())"
    case .reconciledBalance(let id, let balance):
      "reconcile:\(id.uuidString.lowercased()):\(balance.uuidString.lowercased())"
    case .transferFee(let id): "transfer:\(id.uuidString.lowercased()):fee"
    case .remainderWriteOff(let part, let operation): "writeoff:\(part):\(operation)"
    }
  }

  /// A record the app wrote to keep the books right, not a movement of money: the surplus is
  /// inside the money returned, the shortfall left my pocket at the purchase.
  public var isBookkeeping: Bool {
    switch self {
    // The surplus and the shortfall of a reimbursement, and the difference a reconciliation
    // records: money that moved on paper, to make the books agree with what is really there.
    // None of it is spending of the owner's, so none of it goes into the forecast, into the
    // anomalies or into the daily average.
    //
    // The difference used to be excluded by its category — it went to «Не помню», which is
    // a system one — and when it moved to «Сверка», an ordinary category, that exclusion went
    // with it. It is named here now, where it belongs.
    //
    // The difference of one counted balance is inside that count, like the difference of a
    // total; what is written off of a part is money that left at the purchase, like a
    // shortfall.
    case .surplus, .shortfall, .reconciliation, .reconciledBalance, .remainderWriteOff: true
    // A charge «Mark as paid» wrote is real spending; it is only counted as planned rather
    // than as variable. The fee of a transfer is money the bank took.
    case .scheduled, .transferFee: false
    }
  }
}
