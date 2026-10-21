import AppCore
import XCTest

@testable import OhMyMoney

/// How the lists name «bank → account → card» as the owner builds his books up and takes them
/// apart: one bank with one account, a second account, a second card, an account in the archive,
/// a card called like its bank, letters in another case or with «ё». Each step is checked against
/// the name the owner expects to read in a picker and in the «Account» column.
final class AccountsScenarioLabelTests: XCTestCase {
  private let ru = Locale(identifier: "ru_RU")

  private func labels(
    _ accounts: [PaymentMethod], _ cards: [PaymentCard] = [], _ banks: [Bank]
  ) -> AccountLabels {
    AccountLabels(accounts: accounts, cards: cards, banks: banks)
  }

  func testABankWithOneAccountIsCalledByTheBankWhateverTheAccountIsCalled() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Зарплатная", bankId: bank.id)
    XCTAssertEqual(labels([account], [], [bank]).label(account: account.id), "Сбер")
  }

  func testASecondLiveAccountPutsBothUnderTheBankName() {
    let bank = Bank(name: "Т-Банк")
    let debit = PaymentMethod(name: "Дебетовая", bankId: bank.id)
    let savings = PaymentMethod(name: "Накопительный", bankId: bank.id)
    let names = labels([debit, savings], [], [bank])
    XCTAssertEqual(names.label(account: debit.id), "Т-Банк › Дебетовая")
    XCTAssertEqual(names.label(account: savings.id), "Т-Банк › Накопительный")
  }

  func testTheAccountCalledLikeItsBankIsTheBankEvenAmongSeveral() {
    let bank = Bank(name: "Т-Банк")
    let main = PaymentMethod(name: "т-банк", bankId: bank.id)
    let savings = PaymentMethod(name: "Накопительный", bankId: bank.id)
    XCTAssertEqual(labels([main, savings], [], [bank]).label(account: main.id), "Т-Банк")
  }

  /// When the second account goes to the archive, the first is the bank's only one again.
  func testArchivingTheSecondAccountLeavesTheFirstCalledByTheBank() {
    let bank = Bank(name: "ВТБ")
    let live = PaymentMethod(name: "Карта", bankId: bank.id)
    let old = PaymentMethod(name: "Вклад", archived: true, bankId: bank.id)
    let names = labels([live, old], [], [bank])
    XCTAssertEqual(names.label(account: live.id), "ВТБ")
    XCTAssertEqual(
      names.label(account: old.id), "ВТБ › Вклад",
      "an archived account is a peer of the live one, named under the bank")
  }

  func testAnAccountWithNoBankIsNamedByItself() {
    let account = PaymentMethod(name: "Наличные", kind: .cash)
    XCTAssertEqual(labels([account], [], []).label(account: account.id), "Наличные")
  }

  func testAnAccountWhoseBankIsMissingIsNamedByItself() {
    let account = PaymentMethod(name: "Кошелёк", bankId: UUID())
    XCTAssertEqual(labels([account], [], []).label(account: account.id), "Кошелёк")
  }

  func testAnUnknownAccountOrCardHasNoLabel() {
    let names = labels([], [], [])
    XCTAssertNil(names.label(account: UUID()))
    XCTAssertNil(names.label(card: UUID()))
    XCTAssertNil(names.label(account: UUID(), card: UUID()))
  }

  func testACardCalledLikeItsAccountIsTheAccountItself() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    let card = PaymentCard(accountId: account.id, name: "СБЕР")
    XCTAssertEqual(labels([account], [card], [bank]).label(card: card.id), "Сбер")
  }

  func testACardCalledLikeItsBankIsTheAccountItself() {
    let bank = Bank(name: "Альфа")
    let account = PaymentMethod(name: "Текущий", bankId: bank.id)
    let card = PaymentCard(accountId: account.id, name: "альфа")
    XCTAssertEqual(labels([account], [card], [bank]).label(card: card.id), "Альфа")
  }

  func testACardOfItsOwnNameIsFiledUnderItsAccount() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let black = PaymentCard(accountId: account.id, name: "Black")
    XCTAssertEqual(labels([account], [black], [bank]).label(card: black.id), "Т-Банк › Black")
  }

  func testTheColumnIgnoresACardOfAnotherAccount() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    let other = PaymentMethod(name: "Наличные", kind: .cash)
    let foreign = PaymentCard(accountId: other.id, name: "Visa")
    XCTAssertEqual(
      labels([account, other], [foreign], [bank]).label(account: account.id, card: foreign.id),
      "Сбер")
  }

  func testTheColumnNamesTheCardWhenItIsNotTheAccount() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    let visa = PaymentCard(accountId: account.id, name: "Visa")
    XCTAssertEqual(
      labels([account], [visa], [bank]).label(account: account.id, card: visa.id), "Сбер › Visa")
  }

  func testTheColumnWithoutACardSaysTheAccount() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    XCTAssertEqual(labels([account], [], [bank]).label(account: account.id, card: nil), "Сбер")
  }

  func testOneCardOffersOnlyTheAccount() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    let card = PaymentCard(accountId: account.id, name: "Visa")
    let entries = labels([account], [card], [bank])
      .entries(offering: [account], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Сбер"])
  }

  func testTwoCardsOfferTheAccountAndThenEachCardInTheirOrder() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let platinum = PaymentCard(accountId: account.id, name: "Platinum")
    let black = PaymentCard(accountId: account.id, name: "Black")
    let entries = labels([account], [platinum, black], [bank])
      .entries(offering: [account], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Т-Банк", "Т-Банк › Black", "Т-Банк › Platinum"])
    XCTAssertEqual(entries.map(\.isCard), [false, true, true])
    XCTAssertEqual(entries[1].id, black.id)
  }

  func testTheDraggedOrderOfCardsWinsOverTheirNames() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let a = PaymentCard(accountId: account.id, name: "Aaa", sort: 2)
    let z = PaymentCard(accountId: account.id, name: "Zzz", sort: 1)
    let entries = labels([account], [a, z], [bank])
      .entries(offering: [account], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Т-Банк", "Т-Банк › Zzz", "Т-Банк › Aaa"])
  }

  func testTheCardCalledLikeTheAccountIsNotOfferedASecondTime() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let same = PaymentCard(accountId: account.id, name: "Т-Банк")
    let black = PaymentCard(accountId: account.id, name: "Black")
    let entries = labels([account], [same, black], [bank])
      .entries(offering: [account], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Т-Банк", "Т-Банк › Black"])
  }

  func testAnArchivedCardIsNotCountedNorOffered() {
    let bank = Bank(name: "Сбер")
    let account = PaymentMethod(name: "Сбер", bankId: bank.id)
    let live = PaymentCard(accountId: account.id, name: "Visa")
    let old = PaymentCard(accountId: account.id, name: "Mir", archived: true)
    let entries = labels([account], [live, old], [bank])
      .entries(offering: [account], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Сбер"], "one live card is the account itself")
  }

  func testWithoutCardsOnlyAccountsAreOffered() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let a = PaymentCard(accountId: account.id, name: "A")
    let b = PaymentCard(accountId: account.id, name: "B")
    let entries = labels([account], [a, b], [bank])
      .entries(offering: [account], withCards: false, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Т-Банк"])
  }

  func testTheAccountsAreOfferedInTheOrderGiven() {
    let sber = Bank(name: "Сбер")
    let alfa = Bank(name: "Альфа")
    let one = PaymentMethod(name: "Сбер", bankId: sber.id)
    let two = PaymentMethod(name: "Альфа", bankId: alfa.id)
    let entries = labels([one, two], [], [sber, alfa])
      .entries(offering: [one, two], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Сбер", "Альфа"])
  }

  func testTheCardsOfAnAccountNotOfferedAreNotOffered() {
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Т-Банк", bankId: bank.id)
    let other = PaymentMethod(name: "Наличные", kind: .cash)
    let a = PaymentCard(accountId: account.id, name: "A")
    let b = PaymentCard(accountId: account.id, name: "B")
    let entries = labels([account, other], [a, b], [bank])
      .entries(offering: [other], withCards: true, locale: ru)
    XCTAssertEqual(entries.map(\.name), ["Наличные"])
  }

  func testDisplayNameDropsACardOfTheAccountsNameWithYoAndCase() {
    XCTAssertEqual(CardRules.displayName(account: "Счёт", card: " СЧЕТ "), "Счёт")
    XCTAssertEqual(CardRules.displayName(account: "Сбер", card: nil), "Сбер")
    XCTAssertEqual(CardRules.displayName(account: "Сбер", card: "   "), "Сбер")
    XCTAssertEqual(CardRules.displayName(account: "Сбер", card: "Mir"), "Сбер › Mir")
  }
}

/// The rules of a bank's name and place as the owner adds banks one by one, archives one and
/// brings it back, and leaves the order to the alphabet or drags it.
final class AccountsScenarioBankRuleTests: XCTestCase {
  private let ru = Locale(identifier: "ru_RU")

  func testANameIsComparedWithoutCaseSpacesOrYo() {
    let live = Bank(name: "Ёлка Банк")
    let issues = BankRules.validate(Bank(name: "  елка банк "), among: [live])
    XCTAssertEqual(issues, [.nameTaken(live.id)])
  }

  func testABlankNameIsOneIssueOnly() {
    XCTAssertEqual(BankRules.validate(Bank(name: "  "), among: [Bank(name: "")]), [.emptyName])
  }

  func testTheNameOfAnArchivedBankIsFree() {
    let old = Bank(name: "Тинькофф", archived: true)
    XCTAssertTrue(BankRules.validate(Bank(name: "Тинькофф"), among: [old]).isEmpty)
  }

  func testAnArchivedBankMayKeepTheNameALiveOneTook() {
    let live = Bank(name: "Тинькофф")
    let old = Bank(name: "Тинькофф", archived: true)
    XCTAssertTrue(BankRules.validate(old, among: [live, old]).isEmpty)
  }

  func testABankDoesNotClashWithItself() {
    let bank = Bank(name: "Сбер")
    XCTAssertTrue(BankRules.validate(bank, among: [bank]).isEmpty)
  }

  func testLiveNamedFindsOnlyALiveBank() {
    let old = Bank(name: "Сбер", archived: true)
    XCTAssertNil(BankRules.live(named: "сбер", among: [old]))
    let live = Bank(name: "Сбер")
    XCTAssertEqual(BankRules.live(named: " СБЕР", among: [old, live])?.id, live.id)
    XCTAssertNil(BankRules.live(named: "  ", among: [live]))
  }

  func testBanksAreAlphabeticalInRussianUntilTheyAreDragged() {
    let b = Bank(name: "ВТБ")
    let a = Bank(name: "Альфа")
    let s = Bank(name: "сбер")
    XCTAssertEqual(BankRules.ordered([s, b, a], locale: ru).map(\.name), ["Альфа", "ВТБ", "сбер"])
  }

  func testTheDraggedPlaceWinsAndTheArchiveIsLeftOut() {
    let first = Bank(name: "Яндекс", sort: 1)
    let second = Bank(name: "Альфа", sort: 2)
    let old = Bank(name: "Б", sort: 0, archived: true)
    XCTAssertEqual(
      BankRules.ordered([second, old, first], locale: ru).map(\.name), ["Яндекс", "Альфа"])
  }

  func testANewBankGoesLastOnlyOnceBanksHavePlaces() {
    XCTAssertEqual(BankRules.sortForNewBank(among: []), 0)
    XCTAssertEqual(BankRules.sortForNewBank(among: [Bank(name: "A"), Bank(name: "B")]), 0)
    XCTAssertEqual(BankRules.sortForNewBank(among: [Bank(name: "A", sort: 3)]), 4)
  }

  func testABankWithOnlyArchivedAccountsMayGoToTheArchiveButNotBeDeleted() {
    let bank = Bank(name: "Сбер")
    let old = PaymentMethod(name: "Старый", archived: true, bankId: bank.id)
    XCTAssertTrue(BankRules.canBeArchived(bank.id, among: [old]))
    XCTAssertFalse(BankRules.canBeDeleted(bank.id, among: [old]))
  }

  func testABankWithALiveAccountStaysAndAnEmptyBankGoes() {
    let bank = Bank(name: "Сбер")
    let live = PaymentMethod(name: "Сбер", bankId: bank.id)
    XCTAssertFalse(BankRules.canBeArchived(bank.id, among: [live]))
    XCTAssertTrue(BankRules.canBeDeleted(bank.id, among: [PaymentMethod(name: "x")]))
    XCTAssertEqual(BankRules.accounts(under: bank.id, among: [live]).map(\.id), [live.id])
  }

  func testTheFirstBankOfABookStartsTheMainAccountWithACard() {
    let kit = BankRules.startingKit(
      named: "  Т-Банк\n", currency: .rub, accounts: [], banks: [])
    XCTAssertEqual(kit.bank.name, "Т-Банк")
    XCTAssertEqual(kit.account.name, "Т-Банк")
    XCTAssertTrue(kit.account.isDefault)
    XCTAssertEqual(kit.account.bankId, kit.bank.id)
    XCTAssertEqual(kit.card?.name, "Т-Банк")
    XCTAssertEqual(kit.card?.accountId, kit.account.id)
  }

  func testACashBankStartsWithNoCard() {
    let kit = BankRules.startingKit(
      named: "Копилка", kind: .cash, currency: .rub, accounts: [], banks: [])
    XCTAssertNil(kit.card)
  }

  func testABankAfterAnArchivedOnlyBookStartsTheMainAccount() {
    let old = PaymentMethod(name: "Старый", isDefault: true, archived: true)
    let kit = BankRules.startingKit(named: "Новый", currency: nil, accounts: [old], banks: [])
    XCTAssertTrue(kit.account.isDefault, "an archived account is no main account")
  }

  func testANewAccountGoesUnderTheLiveBankOfItsNameOrANewOne() {
    let sber = Bank(name: "Сбер")
    let mine = BankRules.bank(forNewAccountNamed: "сбер ", among: [sber])
    XCTAssertEqual(mine, BankChoice(bank: sber, isNew: false))
    let new = BankRules.bank(forNewAccountNamed: " Альфа ", among: [sber])
    XCTAssertTrue(new.isNew)
    XCTAssertEqual(new.bank.name, "Альфа")
  }

  func testANewAccountDoesNotJoinAnArchivedBankOfItsName() {
    let old = Bank(name: "Сбер", archived: true)
    let choice = BankRules.bank(forNewAccountNamed: "Сбер", among: [old])
    XCTAssertTrue(choice.isNew)
    XCTAssertNotEqual(choice.bank.id, old.id)
  }
}

/// The rules of cards as the owner names them, pays with them, archives them and makes one the
/// main card: a name the entry line would read as another account is refused; the card a
/// purchase takes follows the order the entry asks.
final class AccountsScenarioCardRuleTests: XCTestCase {
  private let sber = PaymentMethod(name: "Сбер")
  private let alfa = PaymentMethod(name: "Альфа", aliases: ["Alfa"])

  func testOnlyACardOrAccountKindStartsWithACard() {
    XCTAssertNotNil(CardRules.startingCard(for: PaymentMethod(name: "A", kind: .card)))
    XCTAssertNotNil(CardRules.startingCard(for: PaymentMethod(name: "A", kind: .account)))
    XCTAssertNil(CardRules.startingCard(for: PaymentMethod(name: "A", kind: .cash)))
    XCTAssertNil(CardRules.startingCard(for: PaymentMethod(name: "  ", kind: .card)))
  }

  func testACardMayCarryItsOwnAccountsName() {
    let card = PaymentCard(accountId: sber.id, name: "Сбер")
    XCTAssertTrue(
      CardRules.validate(card, previous: nil, cards: [], accounts: [sber, alfa]).isEmpty)
  }

  func testACardMayNotCarryAnotherAccountsNameOrAlias() {
    let byName = PaymentCard(accountId: sber.id, name: "альфа")
    XCTAssertEqual(
      CardRules.validate(byName, previous: nil, cards: [], accounts: [sber, alfa]),
      [.nameTaken(owner: .account(alfa.id))])
    let byAlias = PaymentCard(accountId: sber.id, name: "ALFA")
    XCTAssertEqual(
      CardRules.validate(byAlias, previous: nil, cards: [], accounts: [sber, alfa]),
      [.nameTaken(owner: .account(alfa.id))])
  }

  func testAnArchivedAccountsNameIsNeverFree() {
    let old = PaymentMethod(name: "Старый", archived: true)
    let card = PaymentCard(accountId: sber.id, name: "Старый")
    XCTAssertEqual(
      CardRules.validate(card, previous: nil, cards: [], accounts: [sber, old]),
      [.nameTaken(owner: .account(old.id))])
  }

  func testAnArchivedCardsNameIsFree() {
    let old = PaymentCard(accountId: alfa.id, name: "Visa", archived: true)
    let card = PaymentCard(accountId: sber.id, name: "Visa")
    XCTAssertTrue(
      CardRules.validate(card, previous: nil, cards: [old], accounts: [sber, alfa]).isEmpty)
  }

  func testALiveCardOfTheSameAccountTakesTheName() {
    let first = PaymentCard(accountId: sber.id, name: "Visa")
    let second = PaymentCard(accountId: sber.id, name: "visa")
    XCTAssertEqual(
      CardRules.validate(second, previous: nil, cards: [first], accounts: [sber]),
      [.nameTaken(owner: .card(first.id))])
  }

  func testEachTakenAliasIsToldOnceAndAnAliasLikeTheNameIsSkipped() {
    let other = PaymentCard(accountId: alfa.id, name: "Gold", aliases: ["Голд"])
    let card = PaymentCard(
      accountId: sber.id, name: "Mir", aliases: ["mir", " Голд ", "голд", ""])
    XCTAssertEqual(
      CardRules.validate(card, previous: nil, cards: [other], accounts: [sber, alfa]),
      [.otherNameTaken("Голд", owner: .card(other.id))])
  }

  func testACardOfAnArchivedAccountMustWaitButMayItselfBeArchived() {
    let old = PaymentMethod(name: "Старый", archived: true)
    let live = PaymentCard(accountId: old.id, name: "Visa")
    XCTAssertEqual(
      CardRules.validate(live, previous: nil, cards: [], accounts: [old]), [.accountArchived])
    let archived = PaymentCard(accountId: old.id, name: "Visa", archived: true)
    XCTAssertTrue(CardRules.validate(archived, previous: nil, cards: [], accounts: [old]).isEmpty)
  }

  func testCardTakingFindsOnlyALiveCardOfAnotherAccount() {
    let visa = PaymentCard(accountId: alfa.id, name: "Visa", aliases: ["Виза"])
    XCTAssertEqual(CardRules.cardTaking("виза", except: sber.id, cards: [visa])?.id, visa.id)
    XCTAssertNil(CardRules.cardTaking("виза", except: alfa.id, cards: [visa]))
    var archived = visa
    archived.archived = true
    XCTAssertNil(CardRules.cardTaking("Visa", except: sber.id, cards: [archived]))
    XCTAssertNil(CardRules.cardTaking("  ", except: sber.id, cards: [visa]))
  }

  func testResolvingAChoiceGivesTheAccountAndTheCard() {
    let card = PaymentCard(accountId: sber.id, name: "Visa")
    XCTAssertTrue(CardRules.resolve(selection: card.id, cards: [card]) == (sber.id, card.id))
    XCTAssertTrue(CardRules.resolve(selection: sber.id, cards: [card]) == (sber.id, nil))
    XCTAssertTrue(CardRules.resolve(selection: nil, cards: [card]) == (nil, nil))
  }

  func testThePlaceCardIsKeptOnlyOnTheSameAccountAndWhileLive() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    XCTAssertEqual(
      CardRules.cardForNewOperation(
        chosenAccount: sber.id, lastAtPlace: (sber.id, visa.id), cards: [visa]), visa.id)
    XCTAssertNil(
      CardRules.cardForNewOperation(
        chosenAccount: alfa.id, lastAtPlace: (sber.id, visa.id), cards: [visa]))
    var old = visa
    old.archived = true
    XCTAssertNil(
      CardRules.cardForNewOperation(
        chosenAccount: sber.id, lastAtPlace: (sber.id, visa.id), cards: [old]))
    XCTAssertNil(
      CardRules.cardForNewOperation(chosenAccount: sber.id, lastAtPlace: nil, cards: [visa]))
  }

  func testAChangeOfAccountDropsACardOfTheOldOne() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    XCTAssertEqual(CardRules.cardAfterAccountChange(visa.id, to: sber.id, cards: [visa]), visa.id)
    XCTAssertNil(CardRules.cardAfterAccountChange(visa.id, to: alfa.id, cards: [visa]))
    XCTAssertNil(CardRules.cardAfterAccountChange(visa.id, to: nil, cards: [visa]))
  }

  func testTheMainCardIsTheDefaultWhileLive() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    let mir = PaymentCard(accountId: sber.id, name: "Mir")
    var account = sber
    account.mainCardId = mir.id
    XCTAssertEqual(CardRules.defaultCard(account: account, cards: [visa, mir]), mir.id)
    var archivedMir = mir
    archivedMir.archived = true
    XCTAssertEqual(
      CardRules.defaultCard(account: account, cards: [visa, archivedMir]), visa.id,
      "the one live card is left")
  }

  func testTwoLiveCardsWithoutAMainCardLeaveTheCardOpen() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    let mir = PaymentCard(accountId: sber.id, name: "Mir")
    XCTAssertNil(CardRules.defaultCard(account: sber, cards: [visa, mir]))
  }

  func testTheOperationCardFollowsTheOrderTheEntryAsks() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    let mir = PaymentCard(accountId: sber.id, name: "Mir")
    var account = sber
    account.mainCardId = visa.id
    let cards = [visa, mir]
    XCTAssertEqual(
      CardRules.operationCard(
        named: mir.id, withoutCard: true, placeCard: visa.id, account: account, cards: cards),
      mir.id, "a named card wins")
    XCTAssertNil(
      CardRules.operationCard(
        named: nil, withoutCard: true, placeCard: mir.id, account: account, cards: cards),
      "«со счёта» means no card")
    XCTAssertEqual(
      CardRules.operationCard(
        named: nil, withoutCard: false, placeCard: mir.id, account: account, cards: cards),
      mir.id, "the place's card before the main card")
    XCTAssertEqual(
      CardRules.operationCard(
        named: nil, withoutCard: false, placeCard: nil, account: account, cards: cards),
      visa.id)
  }

  func testAMainCardMovedToAnotherAccountIsNoMainCard() {
    let moved = PaymentCard(accountId: alfa.id, name: "Visa")
    var account = sber
    account.mainCardId = moved.id
    XCTAssertNil(CardRules.validMainCard(of: account, cards: [moved]))
  }

  func testArchivingTheMainCardClearsItButAnotherCardChangesNothing() {
    let visa = PaymentCard(accountId: sber.id, name: "Visa")
    var account = sber
    account.mainCardId = visa.id
    XCTAssertNil(CardRules.account(account, afterArchiving: UUID()))
    XCTAssertNil(CardRules.account(account, afterArchiving: visa.id)?.mainCardId)
    XCTAssertNotNil(CardRules.account(account, afterArchiving: visa.id))
  }
}
