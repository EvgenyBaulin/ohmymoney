import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// Someone else's card against a real database: the editor saves it with no balance, no group
/// and no main mark; money moved from it is income in «Помощь семьи» or the category it names,
/// one step of ⌘Z; money of the owner moved onto it is an advance, a gift or a repayment.
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

  func testAnAdvanceOntoTheCardIsATransferAndNotSpending() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let card = try await make(papa())
    // An advance is the default: no question has to be answered for the line to work.
    let saved = try await transfer(from: main, to: card, sent: 300)
    XCTAssertEqual(saved, .done)
    XCTAssertTrue(try liveEntries().isEmpty, "an advance is not spending")
    let books = try await freshBooks()
    XCTAssertEqual(books.dataset.transfers.count, 1)
    let after = try await balance(main.id)
    XCTAssertEqual(after, rub(700), "the money left the owner's account")
    XCTAssertFalse(
      books.balances.keys.contains { $0.accountId == card.id }, "the card still keeps no balance")
  }

  func testAGiftOntoTheCardIsSpendingInGifts() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let card = try await make(papa())
    var form = transferForm(from: main, to: card, sent: 300)
    form.borrowedPurpose = .gift
    let books = try await freshBooks()
    XCTAssertEqual(
      transfers.save(form, occurredAt: noon.addingTimeInterval(-1_800), books: books), .done)
    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty, "a gift is not a transfer")
    let spent = try XCTUnwrap(try liveEntries().first)
    XCTAssertEqual(spent.transaction.kind, .expense)
    XCTAssertEqual(spent.transaction.paymentMethodId, main.id)
    XCTAssertEqual(spent.transaction.amountE4, rub(300))
    let categoryId = try XCTUnwrap(spent.parts.first?.categoryId)
    let category = try XCTUnwrap(after.dataset.categories.first { $0.id == categoryId })
    XCTAssertEqual(category.kind, .expense)
    XCTAssertEqual(
      category.name,
      environment.language(BorrowedCardRules.giftNameKey, table: BorrowedCardText.table))
    let left = try await balance(main.id)
    XCTAssertEqual(left, rub(700))

    // The second gift finds the category made by the first, and ⌘Z takes each back.
    var again = transferForm(from: main, to: card, sent: 100)
    again.borrowedPurpose = .gift
    XCTAssertEqual(
      transfers.save(again, occurredAt: noon.addingTimeInterval(-900), books: after), .done)
    let second = try await freshBooks()
    XCTAssertEqual(
      second.dataset.categories.filter { $0.kind == .expense && $0.name == category.name }.count,
      1)
    store.undo()
    store.undo()
    XCTAssertTrue(try liveEntries().isEmpty)
  }

  func testARepaymentOntoTheCardPaysTheDebtToItsOwner() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(5_000)])
    let person = Person(name: "Папа")
    try XCTUnwrap(environment.references).save(person)
    let card = try await make(papa(person: person.id))
    let debt = Debt(
      direction: .iOwe, type: .personal, name: "Папе", personId: person.id, currency: .rub)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(debts: [debt]))))
    var form = transferForm(from: main, to: card, sent: 2_000)
    form.borrowedPurpose = .debtRepayment
    let books = try await freshBooks()
    XCTAssertEqual(
      transfers.save(form, occurredAt: noon.addingTimeInterval(-1_800), books: books), .done)
    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty)
    let payment = try XCTUnwrap(try liveEntries().first)
    XCTAssertEqual(payment.transaction.debtId, debt.id)
    XCTAssertEqual(payment.transaction.amountE4, rub(2_000))
    let line = try XCTUnwrap(after.dataset.planning.debtEntries.first { $0.debtId == debt.id })
    XCTAssertEqual(line.kind, .payment)
    XCTAssertEqual(line.transactionId, payment.id)
    let left = try await balance(main.id)
    XCTAssertEqual(left, rub(3_000))
  }

  func testARepaymentWithNoDebtToTheOwnerIsRefusedAndWritesNothing() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let card = try await make(papa(person: Person(name: "Папа").id))
    var form = transferForm(from: main, to: card, sent: 300)
    form.borrowedPurpose = .debtRepayment
    let books = try await freshBooks()
    XCTAssertEqual(
      transfers.save(form, occurredAt: noon.addingTimeInterval(-1_800), books: books),
      .refused(.noDebtToRepay))
    XCTAssertTrue(try liveEntries().isEmpty)
    let untouched = try await freshBooks()
    XCTAssertTrue(untouched.dataset.transfers.isEmpty)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertNotEqual(
        TransferText.message(.noDebtToRepay, environment), "borrowed.transfer.refusal.noDebt")
    }
  }

  func testNoMoneyMovesFromOneSomeoneElsesCardToAnother() async throws {
    _ = try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
    let card = try await make(papa())
    let other = try await make(PaymentMethod(name: "Карта мамы", borrowed: BorrowedCardTerms()))
    let refused = try await transfer(from: card, to: other, sent: 300)
    XCTAssertEqual(refused, .refused(.issue(.toBorrowed)))
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertNotEqual(
        TransferText.message(.issue(.toBorrowed), environment), "borrowed.transfer.refusal.to")
    }
  }

  func testATransferWrittenBeforeTheCardWasSomeoneElsesBecomesIncomeWhenItIs() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let own = try await make(PaymentMethod(name: "Старая"), openings: [.rub: rub(9_000)])
    let done = try await transfer(from: own, to: main, sent: 2_000, fee: 20)
    XCTAssertEqual(done, .done)
    let stored = try await storedTransfers()
    XCTAssertEqual(stored.count, 1)
    XCTAssertEqual(try liveEntries().count, 1, "the fee")

    var turned = own
    turned.borrowed = BorrowedCardTerms()
    let books = try await freshBooks()
    XCTAssertEqual(accounts.save(turned, previous: own, books: books), .done)

    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty, "the old transfer is gone")
    let live = try liveEntries()
    XCTAssertEqual(live.count, 1, "the fee went with the transfer; income took its place")
    let income = try XCTUnwrap(live.first)
    XCTAssertEqual(income.transaction.kind, .income)
    XCTAssertEqual(income.transaction.paymentMethodId, main.id)
    XCTAssertEqual(income.transaction.amountE4, rub(2_000))
    let balanceOfMain = try await balance(main.id)
    XCTAssertEqual(balanceOfMain, rub(3_000))

    store.undo()
    let undone = try await freshBooks()
    XCTAssertFalse(try account(own.id).isBorrowed, "one ⌘Z takes the whole change back")
    XCTAssertEqual(undone.dataset.transfers.count, 1)
    XCTAssertEqual(try liveEntries().count, 1, "the fee is back, the income is gone")
  }

  func testAnOldTransferFromTheCardIsRewrittenAsIncomeWhenItIsEdited() async throws {
    let main = try await make(
      PaymentMethod(name: "Т-Банк", isDefault: true), openings: [.rub: rub(1_000)])
    let own = try await make(PaymentMethod(name: "Старая"), openings: [.rub: rub(9_000)])
    let first = try await transfer(from: own, to: main, sent: 2_000)
    XCTAssertEqual(first, .done)
    let stored = try await storedTransfers()
    let old = try XCTUnwrap(stored.first)
    // The card became someone else's without the history following (an older edit of the account).
    var turned = own
    turned.borrowed = BorrowedCardTerms()
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [turned]))))

    var form = TransferForm(
      editing: old, fee: nil, calendar: environment.calendar)
    form.sent = rub(2_500)
    form.received = rub(2_500)
    let books = try await freshBooks()
    XCTAssertEqual(
      transfers.save(form, occurredAt: old.occurredAt, books: books), .done)
    let after = try await freshBooks()
    XCTAssertTrue(after.dataset.transfers.isEmpty)
    let income = try XCTUnwrap(try liveEntries().first)
    XCTAssertEqual(income.transaction.kind, .income)
    XCTAssertEqual(income.transaction.amountE4, rub(2_500))
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
      environment.language("borrowed.transfer.note.advance", table: BorrowedCardText.table))
    XCTAssertEqual(
      BorrowedCardText.transferNote(
        from: main, to: card, categories: [], purpose: .gift, environment),
      "Подарок: запишется расходом в «Подарки», а не переводом.")
    XCTAssertEqual(
      BorrowedCardText.transferNote(
        from: main, to: card, categories: [], purpose: .debtRepayment, environment),
      "Возврат долга: запишется платежом по вашему открытому долгу этому человеку, а не переводом.")
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
