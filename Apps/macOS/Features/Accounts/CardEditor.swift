import AppCore
import SwiftUI

/// A card as the editor holds it until «Сохранить».
struct CardDraft: Equatable {
  var name: String
  var aliases: [String]
  /// The four digits a bank text names the card by, as typed; empty until then.
  var last4: String
  /// Whatever else the owner keeps about the card, free text.
  var details: String

  init(_ card: PaymentCard?) {
    name = card?.name ?? ""
    aliases = card?.aliases ?? []
    last4 = card?.last4 ?? ""
    details = card?.details ?? ""
  }

  /// The digits as they are kept: only the digits of what was typed, `nil` for none.
  var keptLast4: String? {
    let digits = CardDetails.digits(last4)
    return digits.isEmpty ? nil : digits
  }

  /// Four digits or none: anything else is a slip the editor says so about.
  var last4IsValid: Bool { keptLast4.map { $0.count == 4 } ?? true }

  /// The card to save: `previous` with the edits, or a new card of `accountId`.
  func card(previous: PaymentCard?, accountId: UUID) -> PaymentCard {
    var card = previous ?? PaymentCard(accountId: accountId, name: "")
    card.name = name
    card.aliases = aliases
    card.last4 = keptLast4
    let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
    card.details = note.isEmpty ? nil : note
    return card
  }
}

/// The sheet of a card: its name, the account it belongs to, and its other names. «Сохранить» is
/// one step of ⌘Z; a refusal is said under the form.
struct CardEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  /// `nil` for a new card.
  let previous: PaymentCard?
  let accountId: UUID
  /// Called once the sheet is done with: the id of the card saved, `nil` when nothing was
  /// written.
  let finish: (UUID?) -> Void

  @State private var draft: CardDraft
  @State private var refusal: CardRefusal?
  @State private var failed = false

  init(previous: PaymentCard?, accountId: UUID, finish: @escaping (UUID?) -> Void) {
    self.previous = previous
    self.accountId = accountId
    self.finish = finish
    _draft = State(initialValue: CardDraft(previous))
  }

  private var actions: CardActions { CardActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  private var accountName: String {
    actions.accounts.first { $0.id == accountId }?.name ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "card.editor.newTitle" : "card.editor.title"))
        .appFont(.headline)
      Form {
        NameField(
          title: t("card.editor.name"), text: $draft.name, identifier: "card.editor.name")
        LabeledContent {
          Text(verbatim: accountName)
        } label: {
          Text(verbatim: t("card.editor.account"))
        }
        Section {
          AccountOtherNames(names: $draft.aliases)
        } header: {
          Text(verbatim: t("card.editor.otherNames"))
        } footer: {
          Text(verbatim: t("card.editor.otherNamesHint"))
            .foregroundStyle(.secondary)
        }
        Section {
          NameField(
            title: QuickText.t("quick.card.last4", environment), text: $draft.last4,
            identifier: "card.editor.last4")
          if !draft.last4IsValid {
            Label {
              Text(verbatim: QuickText.t("quick.card.last4.bad", environment))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .appFont(.callout)
          }
          NameField(
            title: QuickText.t("quick.card.details", environment), text: $draft.details,
            identifier: "card.editor.details")
        } footer: {
          Text(verbatim: QuickText.t("quick.card.last4.hint", environment) + " "
            + QuickText.t("quick.card.details.hint", environment))
            .foregroundStyle(.secondary)
        }
        Section {
        } footer: {
          Text(verbatim: t("card.editor.hint"))
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      if let refusal {
        CardRefusalNote(refusal: refusal)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(store.isWritingInBackground || !draft.last4IsValid)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 560)
    .onChange(of: draft) { _, _ in refusal = nil }
    .refusedWriteAlert($failed, environment)
  }

  private func save() {
    refusal = nil
    failed = false
    let card = draft.card(previous: previous, accountId: accountId)
    switch actions.save(card, previous: previous) {
    case .done: finish(card.id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}

/// A refusal said under the form it came from, with a symbol, never by colour alone.
struct CardRefusalNote: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let refusal: CardRefusal

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let categories = Dictionary(
      (dataset?.categories ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(
        verbatim: CardText.message(
          refusal, cards: dataset?.cards ?? [], accounts: dataset?.paymentMethods ?? [],
          categories: categories, environment)
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .appFont(.callout)
    .accessibilityElement(children: .combine)
  }
}
