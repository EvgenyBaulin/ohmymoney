import AppCore
import SwiftUI

/// «Объединить с…» of a card, asked before it is made: into which card of the same account, what
/// moves there, which rules give way, and that the expected cashback of past operations follows
/// the kept card's rules from then on. One write and one step of ⌘Z.
struct CardMergeSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let card: PaymentCard
  /// Called once the sheet is done with: whether the cards were merged.
  let finish: (Bool) -> Void

  @State private var target: UUID?
  @State private var refusal: CardRefusal?
  @State private var failed = false

  private var actions: CardActions { CardActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  var body: some View {
    let targets = actions.mergeTargets(for: card)
    let selected = target ?? targets.first?.id
    let plan = selected.flatMap { try? actions.mergePlan(card.id, into: $0).get() }
    let usage = actions.mergeUsage(card.id)
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.format("card.merge.title", table: CardText.table, card.name))
        .appFont(.headline)
      Form {
        Picker(selection: Binding(get: { selected }, set: { target = $0 })) {
          ForEach(targets) { card in
            Text(verbatim: card.name).tag(Optional(card.id))
          }
        } label: {
          Text(verbatim: t("card.merge.into"))
        }
        .accessibilityIdentifier("card.merge.into")
        if let plan {
          Section {
            line(
              environment.format(
                "card.merge.message", table: CardText.table, plan.merged.name, plan.kept.name))
            if let usage {
              line(
                environment.format(
                  "card.merge.moves", table: CardText.table,
                  counts: usage.operations, usage.scheduled))
            }
            if !plan.movedRules.isEmpty {
              line(
                environment.format(
                  "card.merge.rulesMoved", table: CardText.table, counts: plan.movedRules.count))
            }
            if !plan.droppedRules.isEmpty {
              line(
                environment.format(
                  "card.merge.rulesDropped", table: CardText.table,
                  counts: plan.droppedRules.count))
            }
            line(
              environment.format("card.merge.cashback", table: CardText.table, plan.kept.name))
          }
        }
      }
      .formStyle(.grouped)

      if let refusal {
        CardRefusalNote(refusal: refusal)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(t("card.merge.confirm")) { merge(into: selected) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(selected == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 440)
    .refusedWriteAlert($failed, environment)
  }

  private func line(_ text: String) -> some View {
    Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
  }

  private func merge(into keptId: UUID?) {
    guard let keptId else { return }
    refusal = nil
    failed = false
    switch actions.merge(card.id, into: keptId) {
    case .done: finish(true)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
