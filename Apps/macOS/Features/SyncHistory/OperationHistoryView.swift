import AppCore
import AppDatabase
import SwiftUI

/// The tab «История» of an operation: what changed, when and on which device, from the journal
/// of changes the database keeps for ever (`ChangeJournalRepository`). Newest first.
struct OperationHistoryView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let operationId: UUID
  @State private var events: [HistoryEvent]?

  static let table = "SyncHistory"
  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let events {
        if events.isEmpty {
          Text(verbatim: environment.sync == nil ? t("history.empty.dataSet") : t("history.empty"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history.empty")
        } else {
          ForEach(text.rows(events)) { row in
            VStack(alignment: .leading, spacing: 3) {
              HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.title).appFont(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(verbatim: row.when).appFont(.caption).foregroundStyle(.secondary)
              }
              ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).appFont(.caption).foregroundStyle(.secondary)
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .combine)
          }
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .task(id: operationId) { await load() }
  }

  private func load() async {
    guard let stack = environment.stack else {
      events = []
      return
    }
    let repository = ChangeJournalRepository(stack: stack)
    let id = operationId
    events = await Task.detached {
      (try? repository.events(ofOperation: id)) ?? []
    }.value
  }

  private var text: OperationHistoryText {
    let dataset = store.listing?.dataset
    func lookup<T>(
      _ items: [T]?, _ id: KeyPath<T, UUID>, _ name: KeyPath<T, String>
    )
      -> (UUID) -> String?
    {
      let map = Dictionary(
        (items ?? []).map { ($0[keyPath: id], $0[keyPath: name]) },
        uniquingKeysWith: { first, _ in first })
      return { map[$0] }
    }
    var names = OperationHistoryText.Names()
    names.account = lookup(dataset?.paymentMethods, \.id, \.name)
    names.card = lookup(dataset?.cards, \.id, \.name)
    names.category = lookup(dataset?.categories, \.id, \.name)
    names.place = lookup(dataset?.places, \.id, \.name)
    names.person = lookup(dataset?.people, \.id, \.name)
    names.event = lookup(dataset?.events, \.id, \.name)
    names.goal = lookup(dataset?.goals, \.id, \.name)
    let money = environment.money
    let dates = environment.dates
    let language = environment.language
    return OperationHistoryText(
      names: names, hiddenAccounts: environment.shield.covering.ids,
      hiddenCards: environment.shield.coveredCardIds,
      ownDeviceId: environment.sync?.exchange?.deviceId,
      text: { language($0, table: "SyncHistory") },
      money: { money.exact($0, currency: $1) }, moment: { dates.moment($0) },
      currency: store.listing?.entry(operationId)?.transaction.currency ?? .rub)
  }
}
