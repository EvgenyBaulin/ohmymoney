import CoreKit
import Foundation

/// How a receipt of a queue ended.
public enum ReceiptQueueOutcome: Hashable, Sendable {
  /// An operation was written or supplemented.
  case recorded
  /// The receipt was already on an operation.
  case repeated
  /// Nothing readable: no code, not a receipt, a link with no sum.
  case unread
  /// Read, but not written: the owner passed it by, or the write failed.
  case left
}

/// The count at the end of a queue: «записано N, повторов M, не прочитано K».
public struct ReceiptQueueTally: Hashable, Sendable {
  public var recorded = 0
  public var repeated = 0
  public var unread = 0
  public var left = 0

  public init(recorded: Int = 0, repeated: Int = 0, unread: Int = 0, left: Int = 0) {
    self.recorded = recorded
    self.repeated = repeated
    self.unread = unread
    self.left = left
  }

  public var total: Int { recorded + repeated + unread + left }
}

/// Several receipts taken one after another: which one is next and what became of the rest.
public struct ReceiptQueue: Hashable, Sendable {
  public let total: Int
  public private(set) var tally = ReceiptQueueTally()

  public init(total: Int) { self.total = max(0, total) }

  /// How many receipts have ended.
  public var position: Int { tally.total }
  public var isFinished: Bool { position >= total }

  /// Records how the current receipt ended. Nothing counts once the queue is finished.
  public mutating func settle(_ outcome: ReceiptQueueOutcome) {
    guard !isFinished else { return }
    switch outcome {
    case .recorded: tally.recorded += 1
    case .repeated: tally.repeated += 1
    case .unread: tally.unread += 1
    case .left: tally.left += 1
    }
  }
}

/// What a queue does with a read receipt.
public enum ReceiptQueueAction: Hashable, Sendable {
  /// The receipt is on an operation already: count a repeat, write nothing.
  case repeated
  /// The one operation of the same sum gets the time of the receipt.
  case supplement(UUID)
  /// Nothing is near: a new operation.
  case create
  /// Something may be the same purchase, or the receipt is not exact: the owner decides.
  case ask
}

public enum ReceiptQueuePolicy {
  /// A queue writes by itself only what has one obvious answer. A receipt that several
  /// operations fit, that a near sum or the operations of the day may belong to, that was read
  /// from print (it can be misread) or that is a refund with no purchase to go to waits for the
  /// owner.
  public static func action(for proposal: ReceiptProposal, printed: Bool) -> ReceiptQueueAction {
    if case .alreadyRecorded = proposal { return .repeated }
    if printed { return .ask }
    switch proposal {
    case .alreadyRecorded: return .repeated
    case .supplement(let found, _, let others):
      return others.isEmpty ? .supplement(found.id) : .ask
    case .new(let draft):
      if draft.kind == .refund { return .ask }
      let doubtful =
        !draft.nearby.isEmpty || !draft.similar.isEmpty || !draft.sameDay.isEmpty
        || !draft.splitParts.isEmpty
      return doubtful ? .ask : .create
    }
  }
}
