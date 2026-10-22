import AppCore
import SwiftUI

/// «Поставить место по описанию»: operations without a place whose description is exactly the
/// name — or an alias — of a place the owner already has get that place. Nothing is guessed from
/// part of a word, and a name two places share is left alone. Pure, so the preview and the
/// write come from the same plan.
struct PlaceFromNotePlan: Equatable, Sendable {
  struct Proposal: Identifiable, Equatable, Sendable {
    var placeId: UUID
    var placeName: String
    /// The operations that would get the place.
    var ids: [UUID]
    var id: UUID { placeId }
  }

  /// One line per place, the one that would get the most operations first.
  var proposals: [Proposal]

  var operationCount: Int { proposals.reduce(0) { $0 + $1.ids.count } }

  static func build(entries: [TransactionEntry], places: [Place]) -> PlaceFromNotePlan {
    var owners: [String: [UUID]] = [:]
    for place in places where !place.archived {
      for name in [place.name] + place.aliases {
        let key = NameKey.fold(name)
        guard !key.isEmpty, owners[key]?.contains(place.id) != true else { continue }
        owners[key, default: []].append(place.id)
      }
    }
    var grouped: [UUID: [UUID]] = [:]
    for entry in entries {
      let transaction = entry.transaction
      guard transaction.deletedAt == nil, transaction.kind == .expense,
        transaction.placeId == nil, let note = transaction.note
      else { continue }
      let key = NameKey.fold(note)
      guard let matching = owners[key], matching.count == 1, let placeId = matching.first else {
        continue
      }
      grouped[placeId, default: []].append(transaction.id)
    }
    let names = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0.name) })
    var proposals: [Proposal] = []
    for (placeId, ids) in grouped {
      proposals.append(Proposal(placeId: placeId, placeName: names[placeId] ?? "—", ids: ids))
    }
    proposals.sort { left, right in
      if left.ids.count != right.ids.count { return left.ids.count > right.ids.count }
      return left.placeName.localizedCompare(right.placeName) == .orderedAscending
    }
    return PlaceFromNotePlan(proposals: proposals)
  }

  /// The place each operation gets when the owner keeps only `included` lines of the preview.
  func assignments(including included: Set<UUID>) -> [UUID: UUID] {
    var result: [UUID: UUID] = [:]
    for proposal in proposals where included.contains(proposal.placeId) {
      for id in proposal.ids { result[id] = proposal.placeId }
    }
    return result
  }
}

extension TransactionsStore {
  /// Puts places on operations that have none, in one write and one step of ⌘Z: `places` maps an
  /// operation to its place. An operation that got a place meanwhile is left as it is.
  @discardableResult
  public func setPlaces(_ places: [UUID: UUID], file: String = #fileID) -> Bool {
    guard !refuses("setPlaces", file), repository != nil, !isWritingInBackground,
      !places.isEmpty
    else { return false }
    return modifyMany(Array(places.keys), file: file) { fresh in
      guard fresh.transaction.placeId == nil, let place = places[fresh.transaction.id] else {
        return nil
      }
      var changed = fresh
      changed.transaction.placeId = place
      return changed
    }
  }
}

/// The preview of «Поставить место по описанию»: what would get which place, a switch on every
/// line, and one button that writes the lines left on.
struct PlaceFromNoteSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var plan = PlaceFromNotePlan(proposals: [])
  @State private var included: Set<UUID> = []
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("spending.places.setFromNote"))
        .appFont(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(verbatim: t("spending.places.setFromNote.rule"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if plan.proposals.isEmpty {
        Label {
          Text(
            verbatim: loaded
              ? t("spending.places.noneToSet") : environment.language("common.calculating"))
        } icon: {
          Image(systemName: loaded ? "checkmark.circle" : "hourglass")
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.placeFromNote.none")
      } else {
        List {
          ForEach(plan.proposals) { proposal in
            Toggle(isOn: binding(for: proposal.placeId)) {
              HStack {
                Text(verbatim: proposal.placeName)
                Spacer()
                Text(
                  verbatim: SpendingText.counted(
                    "spending.places.operations", environment, count: proposal.ids.count)
                )
                .foregroundStyle(.secondary)
              }
            }
            .accessibilityIdentifier("spending.placeFromNote.line")
          }
        }
        .frame(minHeight: 160)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("spending.places.setPlaces")) { write() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(plan.assignments(including: included).isEmpty || store.isWritingInBackground)
          .accessibilityIdentifier("spending.placeFromNote.apply")
      }
    }
    .padding(20)
    .frame(minWidth: 380, idealWidth: 460, minHeight: 280)
    .task {
      let entries = compute.snapshot?.dataset.entries ?? []
      let places = compute.snapshot?.dataset.places ?? []
      plan = PlaceFromNotePlan.build(entries: entries, places: places)
      included = Set(plan.proposals.map(\.placeId))
      loaded = true
    }
  }

  private func binding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { included.contains(id) },
      set: { on in
        if on { included.insert(id) } else { included.remove(id) }
      })
  }

  private func write() {
    if store.setPlaces(plan.assignments(including: included)) { dismiss() }
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}
