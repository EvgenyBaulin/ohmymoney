import AppCore
import SwiftUI

/// «Кто вы в выписках»: the phones, the name as banks write it, the numbers of the person's own
/// contracts and cards. With them a transfer to one's own phone is a move between own accounts
/// and not a gift to a stranger. One value per line. Kept in the database and the transfer
/// archive, never in a CSV export or a report about a problem.
struct StatementIdentitySheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  private let onSave: (StatementIdentity) -> Bool
  @State private var phones: String
  @State private var names: String
  @State private var contracts: String
  @State private var cards: String
  @State private var failed = false

  init(identity: StatementIdentity, onSave: @escaping (StatementIdentity) -> Bool) {
    self.onSave = onSave
    _phones = State(initialValue: identity.phones.joined(separator: "\n"))
    _names = State(initialValue: identity.names.joined(separator: "\n"))
    _contracts = State(initialValue: identity.contractNumbers.joined(separator: "\n"))
    _cards = State(initialValue: identity.cardMasks.joined(separator: "\n"))
  }

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("import.identity.title")).appFont(.headline)
      Text(verbatim: t("import.identity.body"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      field("import.identity.phones", "import.identity.phones.hint", $phones)
      field("import.identity.names", "import.identity.names.hint", $names)
      field("import.identity.contracts", "import.identity.contracts.hint", $contracts)
      field("import.identity.cards", "import.identity.cards.hint", $cards)
      if failed {
        Label(t("import.identity.failed"), systemImage: "exclamationmark.octagon")
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) {
          if onSave(identity) { dismiss() } else { failed = true }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("import.identity.save")
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 520)
    .accessibilityIdentifier("import.identity")
  }

  private func field(_ title: String, _ hint: String, _ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: t(title)).appFont(.callout.weight(.semibold))
      TextEditor(text: text)
        .appFont(.body.monospacedDigit())
        .frame(minHeight: 48, maxHeight: 72)
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
      Text(verbatim: t(hint)).appFont(.caption).foregroundStyle(.secondary)
    }
  }

  /// What the four boxes hold, a value to a line, blanks left out.
  var identity: StatementIdentity {
    func lines(_ text: String) -> [String] {
      text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
    return StatementIdentity(
      phones: lines(phones), names: lines(names), contractNumbers: lines(contracts),
      cardMasks: lines(cards))
  }
}
