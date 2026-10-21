import Foundation
import Testing

@testable import CoreModel

/// What the model sees of an operation. The shape of these features is part of the model file,
/// so changing any of it means a new `featureVersion` — hence tests that pin them exactly.
@Suite("What the model sees of an operation")
struct CategoryFeaturesTests {
  @Test func textIsFoldedToOneShapeBeforeAnythingIsCounted() {
    #expect(CategoryFeatures.normalize("Кофе, 250₽ — ЁЛКА!") == "кофе # елка")
    #expect(
      CategoryFeatures.normalize("  Taxi   to   the   Airport ") == "taxi to the airport")
    #expect(CategoryFeatures.normalize("счёт №12/34") == "счет # #")
    #expect(CategoryFeatures.normalize("") == "")
  }

  /// Every run of digits becomes one token, so «заказ 12345» and «заказ 67» are the same
  /// order rather than two unrelated things.
  @Test func everyNumberBecomesTheSameToken() {
    #expect(
      CategoryFeatures.words(in: "заказ 12345") == CategoryFeatures.words(in: "заказ 67"))
  }

  /// Three-letter grams are taken inside a word, with its edges marked, so an ending does not
  /// hide a word from itself: «кофе» and «кофею» still share most of their grams.
  @Test func gramsAreTakenInsideAWordWithItsEdgesMarked() {
    #expect(
      CategoryFeatures.grams(in: "кофе") == ["_ко", "коф", "офе", "фе_"])
    let coffee = Set(CategoryFeatures.grams(in: "кофе"))
    let coffees = Set(CategoryFeatures.grams(in: "кофею"))
    #expect(coffee.intersection(coffees).count >= 3)
  }

  @Test func aWordRepeatedInOneNoteIsCountedOnce() {
    #expect(CategoryFeatures.words(in: "кофе кофе кофе") == ["кофе"])
  }

  /// Long notes are bounded: a paste of a whole receipt must not become ten thousand features.
  @Test func theNumberOfFeaturesIsBounded() {
    let long = (0..<500).map { "слово\($0)" }.joined(separator: " ")
    #expect(CategoryFeatures.words(in: long).count <= CategoryFeatures.wordLimit)
    #expect(CategoryFeatures.grams(in: long).count <= CategoryFeatures.gramLimit)
  }

  /// The amount is a bucket, found by comparing whole units — no logarithm, so the same
  /// amount gives the same bucket on every platform for ever.
  @Test func theAmountBecomesABucketThatGrowsWithIt() {
    #expect(CategoryFeatures.amountBucket(whole: 0) == 0)
    #expect(CategoryFeatures.amountBucket(whole: 49) == 0)
    #expect(CategoryFeatures.amountBucket(whole: 50) == 1)
    #expect(
      CategoryFeatures.amountBucket(whole: 250) < CategoryFeatures.amountBucket(whole: 25_000))
    #expect(
      CategoryFeatures.amountBucket(whole: 900_000)
        == CategoryFeatures.amountBucket(whole: 9_000_000),
      "everything above the last threshold is one bucket")
  }

  /// The keys of one example, in the one order the model ever sees them.
  @Test func aFeatureVectorIsSortedAndFreeOfDuplicates() {
    let keys = CategoryFeatures.keys(
      text: "кофе кофе", place: nil, paymentMethod: nil, forWhom: "me", person: nil,
      weekday: 3, amountWhole: 250)

    #expect(keys == keys.sorted())
    #expect(keys.count == Set(keys).count)
    #expect(keys.contains("w:кофе"))
    #expect(keys.contains("d:3"))
    #expect(keys.contains("f:me"))
  }
}
