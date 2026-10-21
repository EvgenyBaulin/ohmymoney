import AppCore
import SwiftUI

/// «Перевод»: money from one account and currency to another — or to another currency of the
/// same account, an exchange. The amount sent, and the amount received when the currencies
/// differ, as the bank shows them, with the rate they imply; an optional fee, written as an
/// expense in «Комиссии» from the account the money left; the day and a comment. Saving is one
/// step of ⌘Z with the fee. When «Комиссии» is in the archive, the first fee brings it back —
/// with its parent when that is archived too — and says so under the fee.
///
/// A transfer dated on the day of a count of a balance it moves, saved after that count, asks
/// whether it happened before it: «Да» puts it just before the count, inside the balance
/// counted; «Нет» after it — or, when the day holds a later count of the other balance, asks
/// about that one too. «Больше не спрашивать для этой сверки» keeps the answer for that
/// count's reconciliation, and what saves next that day is dated by it silently. A time the
/// owner chose («Время») is never asked about: it says itself where the transfer was.
///
/// An edit of a transfer of an account in the archive keeps that account at zero: money the
/// edit would leave on it, or take off it, is moved to or from a live account by a transfer
/// asked for first (`ArchivedMoneySheet`), written in the same step.
///
/// The fields and the walk of the save are the ones the ↓ panel and the form at the side show
/// a transfer in (`TransferFields`, `TransferEntry`); the sheet is for the screens of accounts
/// and the lists of operations.
struct TransferSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  @State private var entry: TransferEntry
  /// Called once the sheet is done with: whether a transfer was written.
  let finish: (Bool) -> Void

  /// Save as soon as the books are read: a transfer named whole elsewhere. What the save asks —
  /// a count of its day, money of an archived account — is asked here all the same.
  let saveAtOnce: Bool

  init(form: TransferForm, saveAtOnce: Bool = false, finish: @escaping (Bool) -> Void) {
    _entry = State(initialValue: TransferEntry(form: form))
    self.saveAtOnce = saveAtOnce
    self.finish = finish
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var transfers: TransferActions { TransferActions(environment: environment, store: store) }

  /// What the account menus offer: the live accounts, and the archived ones `kept` — those of
  /// the transfer being edited —, named as every list of accounts names them (`AccountLabels`):
  /// the bank alone for a bank with one live account, «Банк › Счёт» for one with several.
  static func accountItems(
    all: [PaymentMethod], banks: [Bank], keeping kept: Set<UUID>, locale: Locale
  ) -> [AccountCardChoices.Item] {
    let offered = AccountRules.ordered(
      all.filter { !$0.archived || kept.contains($0.id) }, locale: locale, includeArchived: true)
    return AccountCardChoices.accountItems(
      accounts: offered, banks: banks, among: all, locale: locale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: t(
          entry.form.previous == nil ? "transfer.sheet.title" : "transfer.sheet.editTitle")
      )
      .appFont(.headline)
      TransferFields(entry: entry, layout: .sheet)
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(entry.isSaving || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 640)
    .task {
      guard saveAtOnce else { return }
      await entry.load(transfers)
      save()
    }
    .transferQuestions(entry)
  }

  private func save() {
    entry.save(transfers) { finish(true) }
  }
}
