import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// Someone else's card against a real database: the editor saves it with no balance, no group
/// and no main mark; money moved from it is income in «Помощь семьи» or the category it names,
/// one step of ⌘Z; money of the owner never goes onto it.
final class BorrowedCardTests: AccountsScenarioDatabaseCase {
  private func papa(person: UUID? = nil, category: UUID? = nil) -> PaymentMethod {
    PaymentMethod(
      name: "Карта папы",
      borrowed: BorrowedCardTerms(personId: person, incomeCategoryId: category))
  }

  // MARK: The editor

  func testTheEditorSavesSomeoneElsesCardWithNoGroupNoMainAndNoCushion() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(10_000)])
    let group = AccountGroup(name: "Семья")
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(accountGroups: [group]))))
    let person = Person(name: "Папа")
    try XCTUnwrap(environment.references).save(person)

    var draft = AccountDraft(newIn: .rub)
    draft.name = "Карта папы"
    draft.groupId = group.id
    draft.cushion = true
    draft.isBorrowed = true
    draft.borrowedPersonId = person.id
    let account = draft.account(over: nil)
    XCTAssertEqual(account.borrowed, BorrowedCardTerms(personId: person.id))
    XCTAssertNil(account.groupId, "someone else's money is in no group")
    XCTAssertFalse(account.cushion)
    XCTAssertFalse(account.isDefault)

    let books = try await freshBooks()
    XCTAssertEqual(accounts.save(account, previous: nil, books: books), .done)
    let saved = try self.account(account.id)
    XCTAssertTrue(saved.isBorrowed)
    XCTAssertEqual(saved.borrowed?.personId, person.id)
    XCTAssertEqual(AccountDraft(saved).isBorrowed, true)
    XCTAssertEqual(AccountDraft(saved).borrowedPersonId, person.id)

    let after = try await freshBooks()
    XCTAssertFalse(
      after.balances.keys.contains { $0.accountId == account.id }, "the card keeps no balance")
    let mainBalance = try await balance(main.id)
    XCTAssertEqual(mainBalance, rub(10_000))
  }

  func testTheMainAccountCannotBecomeSomeoneElsesCard() async throws {
    let main = try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
    var turned = main
    turned.borrowed = BorrowedCardTerms()
    let books = try await freshBooks()
    XCTAssertEqual(accounts.save(turned, previous: main, books: books), .refused(.borrowed(.main)))
    XCTAssertFalse(try account(main.id).isBorrowed)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let words = AccountText.message(.borrowed(.main), environment)
      XCTAssertNotEqual(words, "borrowed.editor.mainStays", "\(choice)")
      XCTAssertNotEqual(
        AccountText.message(.borrowed(.creditCard), environment), "borrowed.refusal.ownMoney")
    }
  }

  func testTurningSomeoneElsesCardBackKeepsTheFieldsClean() {
    var draft = AccountDraft(papa(person: UUID()))
    XCTAssertTrue(draft.isBorrowed)
    draft.isBorrowed = false
    XCTAssertNil(draft.account(over: nil).borrowed, "the switch off makes it the owner's own again")
  }

  // MARK: Transfers

  func testMoneyFromTheCardIsIncomeInFamilyHelpOnTheOwnersAccount() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let card = try await make(papa())
    let first = try await transfer(from: card, to: main, sent: 3_000)
    XCTAssertEqual(first, .done)

    let books = try await freshBooks()
    XCTAssertTrue(books.dataset.transfers.isEmpty, "no transfer is written")
    let incomes = try liveEntries()
    XCTAssertEqual(incomes.count, 1)
    let income = try XCTUnwrap(incomes.first)
    XCTAssertEqual(income.transaction.kind, .income)
    XCTAssertEqual(income.transaction.paymentMethodId, main.id)
    XCTAssertEqual(income.transaction.amountE4, rub(3_000))
    let categoryId = try XCTUnwrap(income.parts.first?.categoryId)
    let category = try XCTUnwrap(books.dataset.categories.first { $0.id == categoryId })
    XCTAssertEqual(category.kind, .income)
    XCTAssertNil(category.parentId)
    XCTAssertEqual(
      category.name,
      environment.language(BorrowedCardRules.defaultIncomeNameKey, table: BorrowedCardText.table))
    let afterIncome = try await balance(main.id)
    XCTAssertEqual(afterIncome, rub(4_000))

    // A second transfer finds the category made the first time.
    let second0 = try await transfer(from: card, to: main, sent: 500)
    XCTAssertEqual(second0, .done)
    let second = try await freshBooks()
    XCTAssertEqual(
      second.dataset.categories.filter { $0.kind == .income && $0.name == category.name }.count,
      1)

    store.undo()
    store.undo()
    let undone = try await freshBooks()
    XCTAssertTrue(try liveEntries().isEmpty, "⌘Z takes each income back")
    XCTAssertFalse(
      undone.dataset.categories.contains { $0.id == categoryId && !$0.archived },
      "and the category made with the first one")
  }

  func testMoneyFromTheCardGoesToTheCategoryItNames() async throws {
    let main = try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
    let chosen = CoreKit.Category(kind: .income, name: "От партнёра")
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [chosen]))))
    let card = try await make(papa(category: chosen.id))
    let saved = try await transfer(from: card, to: main, sent: 2_000)
    XCTAssertEqual(saved, .done)
    let income = try XCTUnwrap(try liveEntries().first)
    XCTAssertEqual(income.parts.first?.categoryId, chosen.id)
  }

  func testNoMoneyOfTheOwnersGoesOntoSomeoneElsesCard() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let card = try await make(papa())
    let refused = try await transfer(from: main, to: card, sent: 300)
    XCTAssertEqual(refused, .refused(.issue(.toBorrowed)))
    XCTAssertTrue(try liveEntries().isEmpty)
    let refusedBooks = try await freshBooks()
    XCTAssertTrue(refusedBooks.dataset.transfers.isEmpty)
    let untouched = try await balance(main.id)
    XCTAssertEqual(untouched, rub(1_000))
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertNotEqual(
        TransferText.message(.issue(.toBorrowed), environment), "borrowed.transfer.refusal.to")
    }
  }

  func testTheFormSaysWhatATransferFromOrToTheCardBecomes() async throws {
    let main = try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
    let card = try await make(papa())
    environment.language.choice = .russian
    XCTAssertEqual(
      BorrowedCardText.transferNote(from: card, to: main, categories: [], environment),
      "С чужой карты: запишется доходом в «Помощь семьи».")
    XCTAssertEqual(
      BorrowedCardText.transferNote(from: main, to: card, categories: [], environment),
      environment.language("borrowed.transfer.refusal.to", table: BorrowedCardText.table))
    XCTAssertNil(BorrowedCardText.transferNote(from: main, to: main, categories: [], environment))
    let chosen = CoreKit.Category(kind: .income, name: "От папы")
    var named = card
    named.borrowed?.incomeCategoryId = chosen.id
    XCTAssertEqual(
      BorrowedCardText.transferNote(from: named, to: main, categories: [chosen], environment),
      "С чужой карты: запишется доходом в «От папы».")
  }

  // MARK: Words

  func testTheScreenAndTheSidebarSayWhatWasSpentAndWhoseCardItIs() {
    let person = Person(name: "Папа")
    let card = papa(person: person.id)
    environment.language.choice = .russian
    let badge = BorrowedCardText.badge(card, people: [person], environment)
    XCTAssertEqual(badge, "Карта: Папа")
    XCTAssertEqual(BorrowedCardText.badge(papa(), people: [person], environment), "Чужая карта")
    let hero = BorrowedCardHero.make(spent: rub(4_600), badge: badge, environment: environment)
    XCTAssertEqual(hero.caption, "Потрачено за месяц")
    XCTAssertEqual(hero.figure, environment.money.rounded(rub(4_600)))
    XCTAssertEqual(hero.lines, ["Карта: Папа", "Чужие деньги: остатка и сверки нет."])

    let figure = SidebarFigure.borrowed(
      spent: rub(4_600), badge: badge, money: environment.money,
      spentWords: {
        self.environment.format("borrowed.sidebar.spent", table: BorrowedCardText.table, $0)
      })
    XCTAssertEqual(figure.main, "\(environment.money.rounded(rub(4_600))) за месяц")
    XCTAssertEqual(figure.caption, "Карта: Папа")
    XCTAssertFalse(figure.main.contains("—"))
    let waiting = SidebarFigure.borrowed(
      spent: nil, badge: badge, money: environment.money, spentWords: { $0 })
    XCTAssertEqual(waiting.main, "—")

    environment.language.choice = .english
    XCTAssertEqual(BorrowedCardText.badge(card, people: [person], environment), "Папа's card")
    XCTAssertEqual(
      BorrowedCardHero.make(spent: .zero, badge: "x", environment: environment).caption,
      "Spent this month")
  }

  func testTheCutOfTheSpendingNamesTheCardAndWhoseItIs() {
    let person = Person(name: "Папа")
    let card = papa(person: person.id)
    let unsaid = PaymentMethod(name: "Корпоративная", borrowed: BorrowedCardTerms())
    let own = PaymentMethod(name: "Т-Банк")
    let names = AnalyticsNames(
      dataset: Dataset(people: [person], paymentMethods: [card, unsaid, own]))
    environment.language.choice = .russian
    XCTAssertEqual(
      AnalyticsText.name(of: .paymentMethod(card.id), names, environment),
      "Карта папы · с чужой карты, Папа")
    XCTAssertEqual(
      AnalyticsText.name(of: .paymentMethod(unsaid.id), names, environment),
      "Корпоративная · с чужой карты")
    XCTAssertEqual(AnalyticsText.name(of: .paymentMethod(own.id), names, environment), "Т-Банк")
  }

  func testOnlyTheOwnersIncomeCategoriesAreOffered() {
    let income = CoreKit.Category(kind: .income, name: "Зарплата", sort: 2)
    let help = CoreKit.Category(kind: .income, name: "Помощь семьи", sort: 1)
    let spending = CoreKit.Category(kind: .expense, name: "Family help")
    XCTAssertEqual(
      BorrowedCardSection.incomeChoices([income, spending, help]).map(\.id), [help.id, income.id])
  }
}
