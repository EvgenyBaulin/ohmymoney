import CoreKit
import Foundation

/// The ids of the operation that records a count's difference and of its one part, derived
/// from the count: the same on every create, so a purge, a re-creation and every ⌘Z of either
/// side always name the same row — the operations a step created, the operation an edit
/// started from, the unique `external_id` `reconcile:<rec>:<count>` — and no «Сверка»
/// operation can outlive its count or block the undo stack with a twin.
///
/// Each is the count's 16 bytes XOR a mask of its own. XOR with a fixed mask is its own inverse
/// and one to one, so two counts never share an operation, and neither id is ever the count's.
public enum ReconcileDifferenceIds {
  public static let operationMask: [UInt8] = Array("reconcilediffop!".utf8)
  public static let partMask: [UInt8] = Array("reconcilediffprt".utf8)

  /// The id of the operation that records the difference of `count`.
  public static func operation(forCount count: UUID) -> UUID {
    MaskedId.xor(count, with: operationMask)
  }

  /// The id of the one part of that operation.
  public static func part(forCount count: UUID) -> UUID {
    MaskedId.xor(count, with: partMask)
  }
}

/// An id derived from another by XOR with a 16-byte mask: the same on every run, never the id
/// it came from (the masks are never zero), and given back by the same mask.
enum MaskedId {
  static func xor(_ id: UUID, with mask: [UInt8]) -> UUID {
    precondition(mask.count == 16, "a mask covers the 16 bytes of an id")
    var bytes = id.uuid
    withUnsafeMutableBytes(of: &bytes) { raw in
      for index in raw.indices { raw[index] ^= mask[index] }
    }
    return UUID(uuid: bytes)
  }
}
