import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreInsights

/// «The cached measurement is the measurement»: the quality of the model is what a fresh run
/// gives, whether it came from memory or not, and it is worked out again exactly when an example
/// the model learns from has changed.
@Suite("Model quality cache")
struct ModelQualityCacheTests {
  private static let today = RecomputeAfterOneWriteTests.today

  private func books() -> (data: Dataset, ledger: Ledger) {
    let (_, data) = RecomputeAfterOneWriteTests.dataset(months: 6, density: 3)
    return (data, Ledger(dataset: data, calendar: RecomputeAfterOneWriteTests.calendar))
  }

  @Test func theSecondBuildComesFromMemoryAndEqualsAFreshOne() {
    let (_, ledger) = books()
    let cache = ModelQualityCache()
    let first = ModelQuality.build(ledger: ledger, today: Self.today, cache: cache)
    let second = ModelQuality.build(ledger: ledger, today: Self.today, cache: cache)
    let fresh = ModelQuality.build(ledger: ledger, today: Self.today, cache: ModelQualityCache())

    #expect(second == first)
    #expect(first == fresh)
    #expect(cache.counts.hits == 1 && cache.counts.misses == 1)
  }

  /// A write the model learns nothing from leaves the measurement; a refiled operation does not.
  @Test func anExampleChangedWorksTheMeasurementOutAgain() throws {
    let (data, ledger) = books()
    let cache = ModelQualityCache()
    _ = ModelQuality.build(ledger: ledger, today: Self.today, cache: cache)

    // An operation the model is taught from, filed elsewhere.
    let labelled = Set(LedgerTraining.examples(of: ledger).map(\.partId))
    var entry = try #require(data.entries.first { $0.parts.contains { labelled.contains($0.id) } })
    let other = try #require(
      data.categories.first {
        $0.kind == .expense && $0.systemRole == nil && $0.id != entry.parts[0].categoryId
      })
    entry.parts[0].categoryId = other.id
    let changed = Ledger(
      dataset: data.upserting([entry]), calendar: RecomputeAfterOneWriteTests.calendar)
    let answer = ModelQuality.build(ledger: changed, today: Self.today, cache: cache)

    #expect(cache.counts.misses == 2)
    #expect(
      answer == ModelQuality.build(ledger: changed, today: Self.today, cache: ModelQualityCache()))

    // The same books again: the order of the operations is not what the measurement reads.
    var shuffled = data
    shuffled.entries.reverse()
    let reordered = Ledger(dataset: shuffled, calendar: RecomputeAfterOneWriteTests.calendar)
    let first = ModelQuality.build(ledger: reordered, today: Self.today, cache: ModelQualityCache())
    let base = ModelQuality.build(ledger: ledger, today: Self.today, cache: ModelQualityCache())
    #expect(first.categories == base.categories)
  }
}
