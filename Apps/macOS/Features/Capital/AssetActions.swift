import AppCore
import AppDatabase
import Foundation

/// Why an action on the assets was not taken. Nothing is written then.
enum AssetRefusal: Error, Hashable, Sendable {
  /// The name is empty once the spaces around it are gone.
  case emptyName
  /// A value below zero: a thing is worth nothing at worst.
  case negativeValue
  /// The asset or the valuation is no longer there.
  case notFound
}

/// What became of an action on the assets.
enum AssetActionOutcome: Hashable, Sendable {
  case done
  case refused(AssetRefusal)
  /// The write failed; the store says how.
  case failed
}

/// The actions on the things valued by hand — a car, equipment, a brokerage account, a flat —
/// and on their valuations. Each is one `PlanningChange`: one write, one step of ⌘Z. A new
/// asset is written with its first valuation in that one step, and a deleted one takes its
/// valuations along, which the step keeps, so ⌘Z gives back the whole history.
///
/// The lists an action works over are handed in by the screen — what it shows is what the
/// action is about; the rules that make the change are static, so a test can read them alone.
@MainActor
struct AssetActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  init(_ deps: AppDependencies) {
    environment = deps.environment
    store = deps.store
  }

  // MARK: Rules

  /// An asset as the editor saves it: the name and the note without the spaces around them, an
  /// empty note as none.
  static func cleaned(_ asset: Asset) -> Asset {
    var asset = asset
    asset.name = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = asset.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    asset.note = note.isEmpty ? nil : note
    return asset
  }

  /// What keeps `asset` from being saved with `value`, the first thing only.
  static func refusal(saving asset: Asset, value: AmountE4? = nil) -> AssetRefusal? {
    if cleaned(asset).name.isEmpty { return .emptyName }
    if let value, value.isNegative { return .negativeValue }
    return nil
  }

  /// A new asset with its first valuation — `value` on `day` —, one change.
  static func creating(
    _ asset: Asset, value: AmountE4, on day: DateOnly, at moment: Date
  ) -> Result<PlanningChange, AssetRefusal> {
    if let refusal = refusal(saving: asset, value: value) { return .failure(refusal) }
    let first = AssetValuation(assetId: asset.id, day: day, valueE4: value)
    return .success(
      PlanningChange(
        upsert: PlanningRows(assets: [cleaned(asset)], assetValuations: [first]), at: moment))
  }

  /// A valuation of `assetId` on `day`. A day that has a valuation already keeps one: the one
  /// there takes the new value under its own id, so the step of ⌘Z gives the old value back.
  static func valuing(
    _ assetId: UUID, value: AmountE4, on day: DateOnly, note: String?,
    among valuations: [AssetValuation], at moment: Date
  ) -> Result<PlanningChange, AssetRefusal> {
    guard !value.isNegative else { return .failure(.negativeValue) }
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let sameDay = valuations.first { $0.assetId == assetId && $0.day == day }
    let valuation = AssetValuation(
      id: sameDay?.id ?? UUID(), assetId: assetId, day: day, valueE4: value,
      note: trimmed.isEmpty ? nil : trimmed)
    return .success(
      PlanningChange(upsert: PlanningRows(assetValuations: [valuation]), at: moment))
  }

  /// The valuations of `assetId`, the latest first: what «История оценок» lists.
  static func history(of assetId: UUID, among valuations: [AssetValuation]) -> [AssetValuation] {
    valuations.filter { $0.assetId == assetId }.sorted { $0.day > $1.day }
  }

  /// The latest valuation of `assetId`, if any.
  static func latest(of assetId: UUID, among valuations: [AssetValuation]) -> AssetValuation? {
    history(of: assetId, among: valuations).first
  }

  /// The assets in the order the screen lists them: the live ones first, then those sold or
  /// written off by `today`; inside each, as dragged, then by name.
  static func ordered(_ assets: [Asset], today: DateOnly, locale: Locale) -> [Asset] {
    assets.sorted { lhs, rhs in
      let left = lhs.isDisposed(on: today)
      let right = rhs.isDisposed(on: today)
      if left != right { return !left }
      if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
      return lhs.name.compare(rhs.name, locale: locale) == .orderedAscending
    }
  }

  // MARK: One step of ⌘Z

  /// A new asset and its first valuation.
  func create(_ asset: Asset, value: AmountE4, on day: DateOnly) -> AssetActionOutcome {
    switch Self.creating(asset, value: value, on: day, at: environment.now()) {
    case .failure(let refusal): return .refused(refusal)
    case .success(let change):
      let outcome = apply(change)
      if outcome == .done {
        AppLog.info(
          "capital.asset.saved", .db, "an asset was made with its first valuation",
          [LogPair("asset", .id(asset.id)), LogPair("valuations", .count(1))])
      }
      return outcome
    }
  }

  /// An edit of an asset: its name, kind, currency and note. Its valuations stay as they are.
  func save(_ asset: Asset) -> AssetActionOutcome {
    if let refusal = Self.refusal(saving: asset) { return .refused(refusal) }
    let outcome = apply(
      PlanningChange(
        upsert: PlanningRows(assets: [Self.cleaned(asset)]), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "capital.asset.saved", .db, "an asset was edited",
        [LogPair("asset", .id(asset.id)), LogPair("valuations", .count(0))])
    }
    return outcome
  }

  /// «Новая оценка…»: `value` on `day`, in place of one of that day.
  func value(
    _ assetId: UUID, value: AmountE4, on day: DateOnly, note: String? = nil,
    among valuations: [AssetValuation]
  ) -> AssetActionOutcome {
    switch Self.valuing(
      assetId, value: value, on: day, note: note, among: valuations, at: environment.now())
    {
    case .failure(let refusal): return .refused(refusal)
    case .success(let change):
      let outcome = apply(change)
      if outcome == .done, let valuation = change.upsert.assetValuations.first {
        AppLog.info(
          "capital.valuation.saved", .db, "an asset was valued",
          [LogPair("asset", .id(assetId)), LogPair("valuation", .id(valuation.id))])
      }
      return outcome
    }
  }

  /// A valuation out of «История оценок». The last one may go too: the asset then has none
  /// and counts nothing until it is valued again.
  func delete(valuation: AssetValuation) -> AssetActionOutcome {
    apply(
      PlanningChange(
        delete: PlanningRowIDs(assetValuations: [valuation.id]), at: environment.now()))
  }

  /// «Продано / списано…»: the asset counts through the day before `day`, then it is gone;
  /// `nil` brings it back.
  func dispose(_ asset: Asset, on day: DateOnly?) -> AssetActionOutcome {
    var asset = asset
    asset.disposedOn = day
    return apply(PlanningChange(upsert: PlanningRows(assets: [asset]), at: environment.now()))
  }

  /// «Удалить…»: the asset and its whole history. The step keeps the valuations, so ⌘Z brings
  /// both back.
  func delete(_ asset: Asset) -> AssetActionOutcome {
    let outcome = apply(
      PlanningChange(delete: PlanningRowIDs(assets: [asset.id]), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "capital.asset.deleted", .db, "an asset was deleted with its valuations",
        [LogPair("asset", .id(asset.id))])
    }
    return outcome
  }

  private func apply(_ change: PlanningChange) -> AssetActionOutcome {
    store.apply(change) ? .done : .failed
  }
}
