import CoreKit
import Testing

@testable import CoreSample

@Suite("SeededRandom is a deterministic, cross-platform source of randomness")
struct SeededRandomTests {
  @Test func sameSeedProducesTheSameSequence() {
    var a = SeededRandom(seed: 42)
    var b = SeededRandom(seed: 42)
    let sequenceA = (0..<50).map { _ in a.next() }
    let sequenceB = (0..<50).map { _ in b.next() }
    #expect(sequenceA == sequenceB)
  }

  @Test func differentSeedsProduceDifferentSequences() {
    var a = SeededRandom(seed: 1)
    var b = SeededRandom(seed: 2)
    let sequenceA = (0..<20).map { _ in a.next() }
    let sequenceB = (0..<20).map { _ in b.next() }
    #expect(sequenceA != sequenceB)
  }

  @Test func intStaysWithinTheClosedRange() {
    var rng = SeededRandom(seed: 7)
    for _ in 0..<500 {
      let value = rng.int(in: 3...9)
      #expect((3...9).contains(value))
    }
  }

  @Test func intStaysWithinTheHalfOpenRange() {
    var rng = SeededRandom(seed: 8)
    for _ in 0..<500 {
      let value = rng.int(in: 0..<5)
      #expect((0..<5).contains(value))
    }
  }

  @Test func choiceOnlyReturnsProvidedElements() {
    var rng = SeededRandom(seed: 9)
    let items = ["a", "b", "c"]
    for _ in 0..<200 {
      #expect(items.contains(rng.choice(from: items)))
    }
  }

  @Test func weightedChoiceNeverPicksAZeroWeightItem() {
    var rng = SeededRandom(seed: 10)
    let items: [(value: String, weight: Int)] = [("never", 0), ("always", 1)]
    for _ in 0..<200 {
      #expect(rng.weightedChoice(from: items) == "always")
    }
  }

  @Test func amountStaysWithinTheSpread() {
    var rng = SeededRandom(seed: 11)
    let center = AmountE4(whole: 100)
    let spread = AmountE4(whole: 20)
    for _ in 0..<500 {
      let value = rng.amount(around: center, spread: spread)
      #expect(value.raw >= center.raw - spread.raw)
      #expect(value.raw <= center.raw + spread.raw)
    }
  }

  @Test func chanceRespectsTheZeroAndOneEdges() {
    var rng = SeededRandom(seed: 12)
    for _ in 0..<50 {
      #expect(rng.chance(0, outOf: 10) == false)
      #expect(rng.chance(10, outOf: 10) == true)
    }
  }

  @Test func uuidsAreReproducibleAndDiffer() {
    var a = SeededRandom(seed: 55)
    var b = SeededRandom(seed: 55)
    #expect(a.nextUUID() == b.nextUUID())

    var rng = SeededRandom(seed: 56)
    let first = rng.nextUUID()
    let second = rng.nextUUID()
    #expect(first != second)
  }
}
