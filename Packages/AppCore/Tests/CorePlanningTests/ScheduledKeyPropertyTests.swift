import CoreAccounting
import CoreKit
import Foundation
import Testing

// Synthetic data only.

/// The key an operation of a scheduled payment carries — `sched:<payment>:<due>` for the rest,
/// `sched:<payment>:<due>:<operation>` for a part — read back over randomly drawn payments,
/// dues and operations, and every near miss refused.
@Suite("The keys of scheduled payments read back")
struct ScheduledKeyPropertyTests {
  private struct Dice: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  private static func uuid(_ dice: inout Dice) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &dice) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  private static func due(_ dice: inout Dice) -> DateOnly {
    DateOnly(
      year: Int.random(in: 2020...2032, using: &dice),
      month: Int.random(in: 1...12, using: &dice), day: Int.random(in: 1...28, using: &dice))
  }

  @Test func theRestAndEveryPartOfADueReadAsTheSameLink() {
    var dice = Dice(state: 0x5C4ED)
    for _ in 0..<300 {
      let payment = Self.uuid(&dice)
      let due = Self.due(&dice)
      let expected = OperationLink.scheduled(paymentId: payment, due: due)
      let rest = expected.externalId
      #expect(OperationLink(externalId: rest) == expected)
      #expect(rest.split(separator: ":").count == 3)
      var keys: Set<String> = [rest]
      for _ in 0..<4 {
        let operation = Self.uuid(&dice)
        let part = OperationLink.scheduledPartExternalId(
          paymentId: payment, due: due, operation: operation)
        #expect(part.hasPrefix(rest + ":"))
        #expect(part.split(separator: ":").count == 4)
        #expect(OperationLink(externalId: part) == expected)
        // Upper-case ids written by another tool read the same.
        #expect(
          OperationLink(
            externalId: part.uppercased().replacingOccurrences(
              of: "SCHED", with: "sched")) == expected)
        keys.insert(part)
      }
      // The unique index on `external_id` needs every key of one due to be its own string.
      #expect(keys.count == 5)
    }
  }

  @Test func theKeysOfDifferentDuesAndPaymentsNeverCollide() {
    var dice = Dice(state: 7)
    var seen: [String: String] = [:]
    for index in 0..<400 {
      let payment = Self.uuid(&dice)
      let due = Self.due(&dice)
      let operation = Self.uuid(&dice)
      for key in [
        OperationLink.scheduled(paymentId: payment, due: due).externalId,
        OperationLink.scheduledPartExternalId(paymentId: payment, due: due, operation: operation),
      ] {
        #expect(seen[key] == nil, "key repeated at \(index)")
        seen[key] = key
      }
    }
  }

  @Test func nearMissesAreNotLinks() {
    let payment = UUID().uuidString.lowercased()
    let operation = UUID().uuidString.lowercased()
    let misses = [
      "sched",
      "sched:",
      "sched:\(payment)",
      "sched:\(payment):",
      "sched:\(payment):2026-09-15:",
      "sched:\(payment):2026-09-15:\(operation):extra",
      "sched:\(payment):2026-09-15:not-a-uuid",
      "sched:\(payment):2026-09-15:7",
      "sched:\(payment):2026-9-15x:\(operation)",
      "sched:\(payment):2026-13-45",
      "sched:\(payment):2026-13-45:\(operation)",
      "sched:not-a-uuid:2026-09-15",
      "sched:not-a-uuid:2026-09-15:\(operation)",
      "sched::2026-09-15:\(operation)",
      "scheduled:\(payment):2026-09-15",
    ]
    for key in misses {
      #expect(OperationLink(externalId: key) == nil, "\(key) must not parse")
    }
  }

  @Test func aPartKeyIsNotBookkeepingAndKeepsTheLinkOfItsDue() throws {
    let payment = UUID()
    let due = DateOnly(year: 2026, month: 9, day: 15)
    let key = OperationLink.scheduledPartExternalId(
      paymentId: payment, due: due, operation: UUID())
    let link = try #require(OperationLink(externalId: key))
    #expect(link.isBookkeeping == false)
  }
}
