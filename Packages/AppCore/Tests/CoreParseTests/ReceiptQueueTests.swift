import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Очередь чеков")
struct ReceiptQueueTests {
  static let calendar = ReceiptMatchTests.calendar
  static let receipt = ReceiptMatchTests.receipt

  private func action(
    _ candidates: [ReceiptCandidate], receipt: ReceiptQR = receipt, printed: Bool = false
  ) -> ReceiptQueueAction {
    ReceiptQueuePolicy.action(
      for: ReceiptMatch.propose(receipt, among: candidates, calendar: Self.calendar),
      printed: printed)
  }

  // MARK: The tally

  @Test func theTallyCountsEachOutcome() {
    var queue = ReceiptQueue(total: 5)
    #expect(queue.position == 0 && !queue.isFinished)
    queue.settle(.recorded)
    queue.settle(.recorded)
    queue.settle(.repeated)
    queue.settle(.unread)
    #expect(!queue.isFinished && queue.position == 4)
    queue.settle(.left)
    #expect(queue.isFinished)
    #expect(queue.tally == ReceiptQueueTally(recorded: 2, repeated: 1, unread: 1, left: 1))
    #expect(queue.tally.total == 5)
  }

  @Test func settlingAFinishedQueueChangesNothing() {
    var queue = ReceiptQueue(total: 1)
    queue.settle(.recorded)
    queue.settle(.recorded)
    #expect(queue.tally.recorded == 1)
  }

  @Test func anEmptyQueueIsFinished() {
    #expect(ReceiptQueue(total: 0).isFinished)
    #expect(ReceiptQueue(total: -3).total == 0)
  }

  // MARK: What is written by itself

  @Test func aReceiptAlreadyOnAnOperationIsARepeat() {
    var held = ReceiptMatchTests.candidate("01", day: 29)
    let withNumbers = ReceiptQRParser.parse("t=20261029T183200&s=1250.50&n=1&fn=1&i=2&fp=3")!
    held.receipt = withNumbers.numbers
    #expect(action([held], receipt: withNumbers) == .repeated)
  }

  @Test func oneOperationOfTheSameSumIsSupplementedByItself() {
    let only = ReceiptMatchTests.candidate("01", day: 29)
    #expect(action([only]) == .supplement(only.id))
  }

  @Test func severalOperationsOfTheSameSumAreAskedAbout() {
    let first = ReceiptMatchTests.candidate("01", day: 29)
    let second = ReceiptMatchTests.candidate("02", day: 28)
    #expect(action([first, second]) == .ask)
  }

  @Test func nothingNearIsCreatedByItself() {
    #expect(action([]) == .create)
    let far = ReceiptMatchTests.candidate("01", day: 3, amount: 20_000_000)
    #expect(action([far]) == .create)
  }

  @Test func anythingThatMayBeTheSamePurchaseIsAskedAbout() {
    let nearSum = ReceiptMatchTests.candidate("01", day: 29, amount: 12_500_000)
    #expect(action([nearSum]) == .ask)
    let part = ReceiptMatchTests.candidate("02", day: 29, amount: 1_000_000)
    #expect(action([part]) == .ask)
  }

  /// Printed text can be misread: it is shown to be checked, never written unseen.
  @Test func aReceiptReadFromPrintIsAlwaysAskedAbout() {
    #expect(action([], printed: true) == .ask)
    let only = ReceiptMatchTests.candidate("01", day: 29)
    #expect(action([only], printed: true) == .ask)
  }

  /// A refund is recorded on its purchase: no new operation is made of it.
  @Test func aRefundWithNoOperationToGoToIsAskedAbout() throws {
    let refund = try #require(ReceiptQRParser.parse("t=20261029T183200&s=1250.50&n=2"))
    #expect(action([], receipt: refund) == .ask)
  }
}
