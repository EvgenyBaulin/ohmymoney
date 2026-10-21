import AppCore
import SwiftUI

/// The line of quick entry at the top of the form at the side of the window: the same line and
/// the same reading as the entry line, but checked before it is written. Return shows «Будет
/// записано: …»; Return again («Записать») writes it, «Изменить» leaves it in the fields below,
/// Esc throws the line away. Nothing is written by the first Return.
struct QuickEntryFlow: Hashable, Sendable {
  /// The card «Будет записано» is up.
  private(set) var confirming = false

  enum Step: Equatable {
    /// The line could not be read: nothing happens but the reason.
    case refuse
    /// The card comes up.
    case confirm
    /// «Записать»: the save goes on, with every question it asks.
    case save
  }

  mutating func submit(lineIsReadable: Bool) -> Step {
    if confirming {
      confirming = false
      return .save
    }
    guard lineIsReadable else { return .refuse }
    confirming = true
    return .confirm
  }

  /// The line changed, «Изменить» or Esc: the card goes.
  mutating func dismiss() { confirming = false }
}

/// «кофе, 300 ₽, Продукты, Сбер, сегодня»: the operation the card says will be written, in the
/// order the line is read.
@MainActor
enum QuickEntrySummary {
  static func text(of model: EntryDraftModel, environment: AppEnvironment) -> String {
    if let transfer = model.transfer {
      return text(of: transfer.form, accounts: model.paymentMethods, environment: environment)
    }
    let draft = model.draft
    var words: [String] = []
    if let note = draft.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
      words.append(note)
    }
    words.append(environment.money.exact(draft.amount, currency: draft.currency))
    let categories = model.categories + model.archivedCategories
    if let id = draft.parts.first?.categoryId,
      let name = categories.first(where: { $0.id == id })?.name
    {
      words.append(name)
    } else {
      words.append(environment.language("entry.quick.noCategory", table: "Entry"))
    }
    if let account = model.selectedAccount { words.append(account.name) }
    words.append(
      environment.dates.dayTitle(
        environment.calendar.day(of: draft.occurredAt), today: environment.today,
        language: AppLanguageStrings(
          today: environment.language("common.today"),
          yesterday: environment.language("common.yesterday"))))
    return words.joined(separator: ", ")
  }
}

extension QuickEntrySummary {
  /// «Перевод: Наличные → Сбер, 5,000 ₽, сегодня» — a side not chosen yet is «?».
  static func text(
    of form: TransferForm, accounts: [PaymentMethod], environment: AppEnvironment
  ) -> String {
    func name(_ id: UUID?) -> String { accounts.first { $0.id == id }?.name ?? "?" }
    var words = [
      environment.language("entry.transfer.preview", table: "Entry") + " "
        + "\(name(form.fromAccountId)) → \(name(form.toAccountId))"
    ]
    if let currency = form.fromCurrency {
      words.append(environment.money.exact(form.sent, currency: currency))
    }
    words.append(
      environment.dates.dayTitle(
        form.day, today: environment.today,
        language: AppLanguageStrings(
          today: environment.language("common.today"),
          yesterday: environment.language("common.yesterday"))))
    return words.joined(separator: ", ")
  }
}

/// What the quick line offers under it: the templates and the latest operations whose words
/// begin like the line. A click puts their line in the field.
@MainActor
enum QuickEntrySuggestions {
  static func lines(
    typed: String, entries: [TransactionEntry], money: MoneyFormatter, limit: Int = 3
  ) -> [String] {
    let words = NameKey.fold(typed).split(separator: " ").filter { Int($0) == nil }
    guard let first = words.first else { return [] }
    var seen = Set<String>()
    var lines: [String] = []
    for entry in entries.reversed() where entry.transaction.kind == .expense {
      guard let note = entry.transaction.note, NameKey.fold(note).hasPrefix(first) else {
        continue
      }
      let line = "\(note) \(money.number(entry.transaction.amountE4.decimal))"
      guard seen.insert(NameKey.fold(line)).inserted else { continue }
      lines.append(line)
      if lines.count == limit { break }
    }
    return lines
  }
}
