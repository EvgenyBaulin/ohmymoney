import AppCore
import SwiftUI

/// The words of someone else's card (`BorrowedCardTerms`).
@MainActor
enum BorrowedCardText {
  nonisolated static let table = "BorrowedCard"

  /// «Карта: Папа», or «Чужая карта» when whose it is was not said or the person is gone.
  static func badge(
    _ account: PaymentMethod, people: [Person], _ environment: AppEnvironment
  ) -> String {
    guard let name = personName(of: account, people: people) else {
      return environment.language("borrowed.badge", table: table)
    }
    return environment.format("borrowed.badge.whose", table: table, name)
  }

  /// The name of the income category a transfer from `card` is written in
  /// (`BorrowedCardRules.incomeCategory`): the one there is, or `defaultName` for one to be made.
  nonisolated static func incomeCategoryName(
    of card: PaymentMethod, categories: [CoreKit.Category], defaultName: String
  ) -> String {
    switch BorrowedCardRules.incomeCategory(for: card, categories: categories) {
    case .existing(let id), .revive(let id, _):
      return categories.first { $0.id == id }?.name ?? defaultName
    case .create:
      return defaultName
    }
  }

  /// What the transfer form says under its accounts: that money from someone else's card is
  /// income in its category, or that money cannot go onto one; `nil` for a plain transfer.
  static func transferNote(
    from: PaymentMethod?, to: PaymentMethod?, categories: [CoreKit.Category],
    _ environment: AppEnvironment
  ) -> String? {
    if to?.isBorrowed == true {
      return environment.language("borrowed.transfer.refusal.to", table: table)
    }
    guard let from, from.isBorrowed else { return nil }
    let name = incomeCategoryName(
      of: from, categories: categories,
      defaultName: environment.language(BorrowedCardRules.defaultIncomeNameKey, table: table))
    return environment.format("borrowed.transfer.asIncome", table: table, name)
  }

  /// The name of the person whose card it is; `nil` when not said or not in the reference book.
  nonisolated static func personName(of account: PaymentMethod, people: [Person]) -> String? {
    guard let id = account.borrowed?.personId,
      let name = people.first(where: { $0.id == id })?.name.trimmingCharacters(in: .whitespaces),
      !name.isEmpty
    else { return nil }
    return name
  }
}

/// What the screen of someone else's card shows in place of a balance: «Потрачено за месяц» —
/// the owner's spending paid with it this month —, whose card it is, and that it has no balance.
struct BorrowedCardHero: Equatable {
  let caption: String
  let figure: String
  let lines: [String]

  /// `spent` is in rubles; `badge` says whose card it is (`BorrowedCardText.badge`).
  @MainActor
  static func make(
    spent: AmountE4, badge: String, environment: AppEnvironment
  ) -> BorrowedCardHero {
    BorrowedCardHero(
      caption: environment.language("borrowed.screen.spentMonth", table: BorrowedCardText.table),
      figure: environment.money.rounded(spent),
      lines: [
        badge,
        environment.language("borrowed.screen.noBalance", table: BorrowedCardText.table),
      ])
  }
}

/// The hero of the screen of someone else's card (`BorrowedCardHero`), worked out from the
/// computed snapshot: the spending of the current month paid with the card.
struct BorrowedCardSpentCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let account: PaymentMethod

  var body: some View {
    if let snapshot = compute.snapshot {
      let spent = BorrowedCardSpending.spent(
        ledger: snapshot.ledger, accountId: account.id, month: environment.today.monthKey)
      let hero = BorrowedCardHero.make(
        spent: spent,
        badge: BorrowedCardText.badge(
          account, people: snapshot.dataset.people, environment),
        environment: environment)
      ScreenHero(
        caption: hero.caption, figure: hero.figure, lines: hero.lines,
        figureIdentifier: "account.screen.borrowed.spent")
    }
  }
}

/// «Чужая карта» in the editor of an account: the switch, whose card it is and the income
/// category of a transfer from it to an account of the owner. The main account cannot be
/// someone else's card: its switch is off and says why.
struct BorrowedCardSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Binding var draft: AccountDraft
  let wasMain: Bool

  @State private var people: [Person] = []
  @State private var incomeCategories: [CoreKit.Category] = []

  private func t(_ key: String) -> String {
    environment.language(key, table: BorrowedCardText.table)
  }

  var body: some View {
    Section {
      Toggle(isOn: $draft.isBorrowed) {
        Text(verbatim: t("borrowed.editor.toggle"))
      }
      .disabled(wasMain && !draft.isBorrowed)
      .accessibilityIdentifier("account.editor.borrowed")
      if draft.isBorrowed {
        Picker(selection: $draft.borrowedPersonId) {
          Text(verbatim: t("borrowed.editor.person.none")).tag(UUID?.none)
          ForEach(personChoices, id: \.id) { person in
            Text(verbatim: person.name).tag(UUID?.some(person.id))
          }
        } label: {
          Text(verbatim: t("borrowed.editor.person"))
        }
        .accessibilityIdentifier("account.editor.borrowed.person")
        Picker(selection: $draft.borrowedIncomeCategoryId) {
          Text(verbatim: t("borrowed.editor.income.default")).tag(UUID?.none)
          ForEach(categoryChoices, id: \.id) { category in
            Text(verbatim: category.name).tag(UUID?.some(category.id))
          }
        } label: {
          Text(verbatim: t("borrowed.editor.income"))
        }
        .accessibilityIdentifier("account.editor.borrowed.income")
      }
    } footer: {
      Text(verbatim: footer)
        .foregroundStyle(.secondary)
    }
    .task {
      people = (try? environment.references?.people()) ?? []
      incomeCategories = Self.incomeChoices(store.categories())
    }
  }

  private var footer: String {
    if wasMain && !draft.isBorrowed { return t("borrowed.editor.mainStays") }
    return draft.isBorrowed
      ? t("borrowed.editor.hint") + " " + t("borrowed.editor.incomeHint")
      : t("borrowed.editor.hint")
  }

  /// The live people, and the one the card names even when archived.
  private var personChoices: [Person] {
    people.filter { !$0.archived || $0.id == draft.borrowedPersonId }
  }

  /// The live income categories, and the one the card names even when archived.
  private var categoryChoices: [CoreKit.Category] {
    incomeCategories.filter { !$0.archived || $0.id == draft.borrowedIncomeCategoryId }
  }

  /// The income categories the owner files things in, in the order of the tree: none of the
  /// app's own.
  static func incomeChoices(_ categories: [CoreKit.Category]) -> [CoreKit.Category] {
    let tree = CategoryTree(categories)
    return categories.filter { $0.kind == .income && tree.systemRole(of: $0.id) == nil }
      .sorted { left, right in
        left.sort != right.sort ? left.sort < right.sort : left.name < right.name
      }
  }
}

extension SidebarFigure {
  /// The figure of someone else's card in a list of accounts (`borrowed(spent:…)`): what was
  /// spent with it this month as `snapshot` has it, over whose card it is.
  @MainActor
  static func borrowed(
    _ account: PaymentMethod, snapshot: DataSnapshot?, environment: AppEnvironment
  ) -> SidebarFigure {
    let spent = snapshot.map {
      BorrowedCardSpending.spent(
        ledger: $0.ledger, accountId: account.id, month: environment.today.monthKey)
    }
    return borrowed(
      spent: spent,
      badge: BorrowedCardText.badge(account, people: snapshot?.dataset.people ?? [], environment),
      money: environment.money,
      spentWords: {
        environment.format("borrowed.sidebar.spent", table: BorrowedCardText.table, $0)
      })
  }
}
