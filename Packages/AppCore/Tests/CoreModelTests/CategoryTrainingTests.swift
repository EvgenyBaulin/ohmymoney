import CoreKit
import Foundation
import Testing

@testable import CoreModel

/// What the model may learn from, and what it must not.
@Suite("What the model may learn from, and what it must not")
struct CategoryTrainingTests {
  private func row(
    category: UUID? = UUID(), systemRole: SystemRole? = nil,
    source: CategorySource = .manual, externalId: String? = nil, deleted: Bool = false
  ) -> CategoryTraining.Row {
    CategoryTraining.Row(
      partId: UUID(), categoryId: category, systemRole: systemRole, categorySource: source,
      externalId: externalId, isDeleted: deleted,
      query: CategoryQuery(
        day: DateOnly(year: 2026, month: 9, day: 20), weekday: 1, kind: .expense, text: "кофе",
        amountWhole: 250))
  }

  @Test func anOperationTheOwnerFiledThemselvesIsLearnedFrom() {
    #expect(CategoryTraining.isLabelled(row()))
    #expect(CategoryTraining.isLabelled(row(source: .history)))
    #expect(CategoryTraining.isLabelled(row(source: .template)))
  }

  /// Parts in system categories are never learned from: Goals, Loans, «Не помню»,
  /// «Доплаты» say nothing about what a thing was.
  @Test func aSystemCategoryIsNotEvidence() {
    for role in SystemRole.allCases {
      #expect(
        !CategoryTraining.isLabelled(row(systemRole: role)), "\(role.rawValue) was learned from")
    }
  }

  /// An operation the application wrote itself is not the owner filing anything.
  @Test func whatTheApplicationWroteItselfIsNotEvidence() {
    #expect(!CategoryTraining.isLabelled(row(externalId: "sched:1")))
    #expect(!CategoryTraining.isLabelled(row(externalId: "reimb:1")))
    #expect(!CategoryTraining.isLabelled(row(externalId: "reconcile:1")))
  }

  /// And neither is the model's own guess: learning from it is how one confident mistake
  /// becomes a habit.
  @Test func theModelDoesNotLearnFromItsOwnGuesses() {
    #expect(!CategoryTraining.isLabelled(row(source: .model)))
  }

  @Test func aPartWithoutACategoryOrADeletedOneIsNotEvidence() {
    #expect(!CategoryTraining.isLabelled(row(category: nil)))
    #expect(!CategoryTraining.isLabelled(row(deleted: true)))
  }

  /// The fingerprint says whether anything worth retraining on has changed — and says it
  /// without keeping the examples.
  @Test func theFingerprintChangesOnlyWhenTheExamplesDo() {
    let rows = (0..<20).map { _ in row() }
    let examples = CategoryTraining.examples(from: rows)
    #expect(
      CategoryTraining.fingerprint(of: examples)
        == CategoryTraining.fingerprint(of: examples.reversed()), "the order is not a change")

    var changed = examples
    changed[0] = CategoryExample(
      query: changed[0].query, partId: changed[0].partId, categoryId: UUID())
    #expect(
      CategoryTraining.fingerprint(of: examples) != CategoryTraining.fingerprint(of: changed))
  }

  /// The pipeline trains the model again when the data changed: it learns the words, the
  /// place, the payment method, for whom and the amount's bucket, so an edit of any of them
  /// on a labelled operation is a change — «такси домой» renamed «кафе у дома» must not keep
  /// answering Transport from the old file. An edit the model cannot see is not one.
  @Test func theFingerprintChangesWhenWhatTheModelLearnsDoes() {
    let examples = CategoryTraining.examples(from: (0..<20).map { _ in row() })
    let before = CategoryTraining.fingerprint(of: examples)
    let edits: [(String, (inout CategoryQuery) -> Void)] = [
      ("note", { $0.text = "кафе у дома" }),
      ("place", { $0.placeId = UUID() }),
      ("payment method", { $0.paymentMethodId = UUID() }),
      ("for whom", { $0.forWhom = "partner" }),
      ("person", { $0.forPersonId = UUID() }),
      ("amount", { $0.amountWhole = 50_000 }),
    ]
    for (name, edit) in edits {
      var changed = examples
      edit(&changed[0].query)
      #expect(before != CategoryTraining.fingerprint(of: changed), "\(name) edit unseen")
    }

    var sameBucket = examples
    sameBucket[0].query.amountWhole = 260
    #expect(before == CategoryTraining.fingerprint(of: sameBucket))
  }

  /// A note, a place or an amount edited under the same category is a change too: the model
  /// learned the words, and a model kept from before the edit would hold words the ledger no
  /// longer has. A correction taken back from it would then take back counts it never had.
  @Test func theFingerprintChangesWhenWhatIsLearnedOfAnExampleDoes() {
    let examples = CategoryTraining.examples(from: (0..<20).map { _ in row() })
    var renamed = examples
    renamed[0].query.text = "something else entirely"
    #expect(
      CategoryTraining.fingerprint(of: examples) != CategoryTraining.fingerprint(of: renamed))

    var moved = examples
    moved[0].query.placeId = UUID()
    #expect(CategoryTraining.fingerprint(of: examples) != CategoryTraining.fingerprint(of: moved))

    var repriced = examples
    repriced[0].query.amountWhole = 1_000_000
    #expect(
      CategoryTraining.fingerprint(of: examples) != CategoryTraining.fingerprint(of: repriced))
  }
}
