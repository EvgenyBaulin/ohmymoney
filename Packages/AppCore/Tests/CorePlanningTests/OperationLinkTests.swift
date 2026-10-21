import CoreAccounting
import CoreKit
import Foundation
import Testing

@Suite struct OperationLinkTests {
  @Test func everyKindReadsBackWhatItWrites() throws {
    let payment = UUID()
    let reconciliation = UUID()
    let links: [OperationLink] = [
      .surplus(reimbursement: "129"), .shortfall(reimbursement: "129", part: "1151"),
      .scheduled(paymentId: payment, due: DateOnly(year: 2026, month: 9, day: 30)),
      .reconciliation(reconciliation),
      .reconciledBalance(reconciliation: reconciliation, balance: payment),
      .transferFee(payment),
      .remainderWriteOff(part: "1151", operation: "77"),
    ]
    for link in links {
      #expect(OperationLink(externalId: link.externalId) == link)
    }
    #expect(
      links[2].externalId == "sched:\(payment.uuidString.lowercased()):2026-09-30")
    let r = reconciliation.uuidString.lowercased()
    let p = payment.uuidString.lowercased()
    #expect(links[4].externalId == "reconcile:\(r):\(p)")
    #expect(links[5].externalId == "transfer:\(p):fee")
    #expect(links[6].externalId == "writeoff:1151:77")
  }

  /// A total of the time before accounts keeps being read the way it was written.
  @Test func theTwoKeysOfAReconciliationAreTold() throws {
    let reconciliation = UUID()
    let balance = UUID()
    let r = reconciliation.uuidString.lowercased()
    #expect(OperationLink(externalId: "reconcile:\(r)") == .reconciliation(reconciliation))
    #expect(
      OperationLink(externalId: "reconcile:\(r):\(balance.uuidString.lowercased())")
        == .reconciledBalance(reconciliation: reconciliation, balance: balance))
    #expect(OperationLink(externalId: "reconcile:\(r):row") == nil)
    #expect(OperationLink(externalId: "transfer:\(r)") == nil)
    #expect(OperationLink(externalId: "transfer:\(r):tip") == nil)
    #expect(OperationLink(externalId: "transfer:x:fee") == nil)
    #expect(OperationLink(externalId: "writeoff::77") == nil)
    #expect(OperationLink(externalId: "writeoff:1151") == nil)
  }

  @Test func otherIdsAreNotLinks() {
    #expect(OperationLink(externalId: nil) == nil)
    #expect(OperationLink(externalId: "import:42") == nil)
    #expect(OperationLink(externalId: "sched:not-a-uuid:2026-09-30") == nil)
  }

  /// A charge the app wrote for a scheduled payment is the owner's real spending — it is only
  /// counted elsewhere. Everything else the app writes for its own books is not spending at
  /// all: the surplus and the shortfall of a reimbursement, and the difference of a
  /// reconciliation.
  @Test func everythingTheAppWritesForItsBooksIsBookkeeping() {
    #expect(OperationLink.surplus(reimbursement: "1").isBookkeeping)
    #expect(OperationLink.shortfall(reimbursement: "1", part: "2").isBookkeeping)
    #expect(OperationLink.reconciliation(UUID()).isBookkeeping)
    #expect(OperationLink.reconciledBalance(reconciliation: UUID(), balance: UUID()).isBookkeeping)
    #expect(OperationLink.remainderWriteOff(part: "1", operation: "2").isBookkeeping)
    #expect(
      !OperationLink.scheduled(paymentId: UUID(), due: DateOnly(year: 2026, month: 9, day: 1))
        .isBookkeeping)
    // The fee of a transfer is money the bank took: spending like any other.
    #expect(!OperationLink.transferFee(UUID()).isBookkeeping)
  }
}
