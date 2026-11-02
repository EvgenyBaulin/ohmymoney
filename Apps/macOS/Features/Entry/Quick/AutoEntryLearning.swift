import AppCore
import Foundation

/// The owner's corrections of the shops of bank texts (`AutoEntryNames`): what a text of a bank
/// becomes in the line, and what the owner wrote it as. The names are kept in the `settings`
/// table (`autoEntry.names`), so they travel in the archive; which draft came from which shop is
/// a habit of this Mac (`autoEntry.pending`, `UserDefaults`) and is forgotten once the draft is
/// written.
@MainActor
enum AutoEntryLearning {
  nonisolated static let pendingKey = "autoEntry.pending"
  nonisolated static let fingerprintsKey = "autoEntry.fingerprints"

  static func names(_ environment: AppEnvironment) -> AutoEntryNames {
    AutoEntryNames.decoded((try? environment.settings?.string(AutoEntryNames.settingsKey)) ?? nil)
  }

  /// A draft made from a text of a bank: the shop as the bank spelled it, to learn from when the
  /// owner finishes the draft, and the fingerprint of the operation (`AutoEntrySuggestion`), so
  /// the SMS and the push of one purchase make one draft even across a restart. Fields only,
  /// never the text.
  static func remember(
    draft id: UUID, merchant: String?, fingerprint: String? = nil,
    defaults: UserDefaults = .standard
  ) {
    if let merchant {
      var pending = defaults.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
      pending[id.uuidString] = merchant
      defaults.set(pending, forKey: pendingKey)
    }
    if let fingerprint {
      var prints = defaults.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
      prints[id.uuidString] = fingerprint
      defaults.set(prints, forKey: fingerprintsKey)
    }
  }

  /// The fingerprints of the operations that wait in `drafts`.
  static func waitingFingerprints(
    _ drafts: [PendingDraft], defaults: UserDefaults = .standard
  ) -> Set<String> {
    let prints = defaults.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
    let waiting = Set(drafts.filter(\.isWaiting).map(\.id.uuidString))
    let kept = prints.filter { waiting.contains($0.key) }
    // A draft written or thrown away takes its fingerprint along.
    if kept.count != prints.count { defaults.set(kept, forKey: fingerprintsKey) }
    return Set(kept.values)
  }

  /// The shop a draft was made from, taken off the list.
  static func takeMerchant(ofDraft id: UUID, defaults: UserDefaults = .standard) -> String? {
    var pending = defaults.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
    let merchant = pending.removeValue(forKey: id.uuidString)
    defaults.set(pending, forKey: pendingKey)
    return merchant
  }

  /// The operation of `merchant` was written with `placeId`: the place's name is what the bank's
  /// spelling is offered as from now on. Says whether anything was learned.
  @discardableResult
  static func written(
    merchant: String?, placeId: UUID?, environment: AppEnvironment
  ) -> Bool {
    guard let merchant, let placeId,
      let place = environment.vocabulary.places.first(where: { $0.id == placeId })
    else { return false }
    var names = names(environment)
    guard names.learn(merchant: merchant, name: place.name), let text = names.encoded() else {
      return false
    }
    let saved = AppEnvironment.attempt("autoEntry.names", on: environment.settings) {
      try $0.set(AutoEntryNames.settingsKey, to: text)
    }
    if saved {
      AppLog.info("autoEntry.learned", .db, "a shop of a bank text was given the owner's name")
    }
    return saved
  }

  /// The message with the shop as the owner named it before, when he did.
  nonisolated static func applying(
    _ names: AutoEntryNames, to message: BankMessage
  ) -> BankMessage {
    guard let merchant = message.merchant, let name = names.name(for: merchant) else {
      return message
    }
    var renamed = message
    renamed.merchant = name
    return renamed
  }
}
