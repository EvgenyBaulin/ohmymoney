import AppCore
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The index of Spotlight as the app uses it. A seam: the app writes the system's index on this
/// Mac, a test keeps what it was given.
protocol SpotlightIndexing: Sendable {
  func replace(with items: [SpotlightPlan.Item]) async
  func removeAll() async
}

struct SystemSpotlightIndex: SpotlightIndexing {
  /// One domain for every operation: switching Spotlight off or a new set of items wipes the
  /// whole of it in one call.
  static let domain = "io.github.EvgenyBaulin.ohmymoney.operations"

  func replace(with items: [SpotlightPlan.Item]) async {
    let index = CSSearchableIndex.default()
    try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    guard !items.isEmpty else { return }
    try? await index.indexSearchableItems(items.map(SpotlightIndexer.searchable))
  }

  func removeAll() async {
    try? await CSSearchableIndex.default().deleteSearchableItems(
      withDomainIdentifiers: [Self.domain])
  }
}

/// Operations in Spotlight: off until the owner turns it on in Settings (`spotlight.enabled`, this
/// Mac). Only the description and the place go into the index (`SpotlightPlan`) — no amount, no
/// category, no account — and never an operation of a hidden account. Turned off, the index is
/// emptied at once. The index is built on this Mac only: Core Spotlight keeps it on the device.
@MainActor
final class SpotlightIndexer {
  static let shared = SpotlightIndexer(index: SystemSpotlightIndex())

  nonisolated static let enabledKey = "spotlight.enabled"

  private let index: any SpotlightIndexing
  var defaults: UserDefaults = .standard
  /// What the index holds now, so a change of the data that changes no item writes nothing.
  private var indexed: [SpotlightPlan.Item]?

  init(index: any SpotlightIndexing) {
    self.index = index
  }

  var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

  /// The index as the data says it should be now.
  func refresh(_ dependencies: AppDependencies) async {
    guard let snapshot = dependencies.compute.wholeSnapshot else { return }
    let dataset = snapshot.ledger.dataset
    let places = Dictionary(
      dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let items = SpotlightPlan.items(
      dataset.entries, enabled: isEnabled,
      hiddenAccounts: HiddenAccounts(accounts: dataset.paymentMethods).ids,
      placeName: { places[$0] })
    guard items != indexed else { return }
    indexed = items
    if items.isEmpty {
      await index.removeAll()
    } else {
      await index.replace(with: items)
    }
    AppLog.info(
      "spotlight.indexed", .ui, "the Spotlight index was rewritten",
      [LogPair("count", .count(items.count))])
  }

  /// Switched off: nothing stays in the index.
  func turnOff() async {
    defaults.set(false, forKey: Self.enabledKey)
    indexed = []
    await index.removeAll()
  }

  nonisolated static func searchable(_ item: SpotlightPlan.Item) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    attributes.title = item.title
    attributes.contentDescription = item.place
    return CSSearchableItem(
      uniqueIdentifier: item.id, domainIdentifier: SystemSpotlightIndex.domain,
      attributeSet: attributes)
  }
}
