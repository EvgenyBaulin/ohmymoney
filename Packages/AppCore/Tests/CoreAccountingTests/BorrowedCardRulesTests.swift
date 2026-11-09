import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

// Synthetic data only.

@Suite("Someone else's card: its rules")
struct BorrowedCardRulesTests {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "B0000000-0000-0000-0000-%012d", number))!
  }

  let own = PaymentMethod(id: id(1), name: "Моя", currency: .rub, isDefault: true)
  let papa = PaymentMethod(
    id: id(2), name: "Карта папы", currency: .rub, borrowed: BorrowedCardTerms(personId: id(90)))

  func transfer(from: UUID, to: UUID, _ whole: Int64 = 5_000) -> Transfer {
    Transfer(
      id: Self.id(70), occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      fromAccountId: from, fromCurrency: .rub, fromAmountE4: AmountE4(whole: whole),
      toAccountId: to, toCurrency: .rub, toAmountE4: AmountE4(whole: whole), note: "на обед")
  }

  @Test func theTermsMakeTheAccountSomeoneElsesAndTakeItsBalanceAway() {
    #expect(papa.isBorrowed)
    #expect(!papa.hasBalance)
    #expect(!own.isBorrowed)
    #expect(own.hasBalance)
  }

  @Test func onlyAnAccountWhoseMoneyNeedNotBeTheOwnersMayBeSomeoneElses() {
    #expect(BorrowedCardRules.issue(papa) == nil)
    #expect(BorrowedCardRules.issue(own) == nil, "the owner's own account is no question")
    var main = papa
    main.isDefault = true
    #expect(BorrowedCardRules.issue(main) == .main)
    var credit = papa
    credit.credit = CreditCardTerms(
      limitE4: AmountE4(whole: 50_000), grace: .fromPurchase(days: 55))
    #expect(BorrowedCardRules.issue(credit) == .creditCard)
    var deposit = papa
    deposit.interest = DepositTerms(rate: 10, period: .monthly)
    #expect(BorrowedCardRules.issue(deposit) == .deposit)
    var cushion = papa
    cushion.cushion = true
    #expect(BorrowedCardRules.issue(cushion) == .cushion)
  }

  @Test func moneyOfTheOwnersMayGoOntoSomeoneElsesCardButNotFromOneCardToAnother() {
    let accounts = [own, papa]
    #expect(
      TransferRules.validate(transfer(from: own.id, to: papa.id), accounts: accounts) == nil,
      "an advance, a gift or a repayment: the form asks which")
    var mama = papa
    mama.id = Self.id(3)
    mama.name = "Карта мамы"
    #expect(
      TransferRules.validate(
        transfer(from: papa.id, to: mama.id), accounts: accounts + [mama]) == .toBorrowed)
    #expect(
      TransferRules.validate(transfer(from: papa.id, to: own.id), accounts: accounts) == nil,
      "money from the card is allowed: the form writes it as income")
    #expect(BorrowedCardRules.isIncome(fromAccountId: papa.id, accounts: accounts))
    #expect(!BorrowedCardRules.isIncome(fromAccountId: own.id, accounts: accounts))
    #expect(!BorrowedCardRules.isIncome(fromAccountId: nil, accounts: accounts))
  }

  @Test func moneyFromTheCardIsIncomeOnTheAccountItArrivedAt() {
    let category = Self.id(50)
    let draft = BorrowedCardRules.incomeDraft(
      transfer: transfer(from: papa.id, to: own.id), categoryId: category)
    #expect(draft.kind == .income)
    #expect(draft.paymentMethodId == own.id)
    #expect(draft.amount == AmountE4(whole: 5_000))
    #expect(draft.currency == .rub)
    #expect(draft.note == "на обед")
    #expect(draft.parts.count == 1)
    #expect(draft.parts.first?.categoryId == category)
    #expect(draft.parts.first?.amount == AmountE4(whole: 5_000))
    #expect(draft.parts.first?.quality == nil, "an income has no rating")
  }

  @Test func theCategoryTheCardNamesComesFirst() {
    let chosen = CoreKit.Category(id: Self.id(51), kind: .income, name: "От партнёра")
    let family = CoreKit.Category(id: Self.id(52), kind: .income, name: "Помощь семьи")
    var card = papa
    card.borrowed?.incomeCategoryId = chosen.id
    #expect(
      BorrowedCardRules.incomeCategory(for: card, categories: [family, chosen])
        == .existing(chosen.id))
  }

  @Test func withoutAChoiceTheDefaultIsFoundByNameAmongIncomeOnly() {
    // The starter set's «Помощь родным» is spending, and its English name is "Family help".
    let spending = CoreKit.Category(id: Self.id(53), kind: .expense, name: "Family help")
    let family = CoreKit.Category(id: Self.id(54), kind: .income, name: " помощь СЕМЬИ ")
    #expect(
      BorrowedCardRules.incomeCategory(for: papa, categories: [spending, family])
        == .existing(family.id))
    #expect(
      BorrowedCardRules.incomeCategory(for: papa, categories: [spending])
        == .create(nameKey: BorrowedCardRules.defaultIncomeNameKey))
    let english = CoreKit.Category(id: Self.id(55), kind: .income, name: "Family help")
    #expect(
      BorrowedCardRules.incomeCategory(for: papa, categories: [spending, english])
        == .existing(english.id))
  }

  @Test func aChosenCategoryThatIsNoIncomeOrIsGoneFallsBackToTheDefault() {
    let spending = CoreKit.Category(id: Self.id(56), kind: .expense, name: "Кафе")
    let family = CoreKit.Category(id: Self.id(57), kind: .income, name: "Помощь семьи")
    var card = papa
    card.borrowed?.incomeCategoryId = spending.id
    #expect(
      BorrowedCardRules.incomeCategory(for: card, categories: [spending, family])
        == .existing(family.id))
    card.borrowed?.incomeCategoryId = Self.id(99)
    #expect(
      BorrowedCardRules.incomeCategory(for: card, categories: [family]) == .existing(family.id))
  }

  @Test func anArchivedCategoryComesBackRatherThanASecondIsMade() {
    let parent = CoreKit.Category(id: Self.id(58), kind: .income, name: "Семья", archived: true)
    let chosen = CoreKit.Category(
      id: Self.id(59), parentId: parent.id, kind: .income, name: "От папы")
    var card = papa
    card.borrowed?.incomeCategoryId = chosen.id
    #expect(
      BorrowedCardRules.incomeCategory(for: card, categories: [parent, chosen])
        == .revive(chosen.id, parent: parent.id))
    let archivedFamily = CoreKit.Category(
      id: Self.id(60), kind: .income, name: "Помощь семьи", archived: true)
    #expect(
      BorrowedCardRules.incomeCategory(for: papa, categories: [archivedFamily])
        == .revive(archivedFamily.id, parent: nil))
  }

  @Test func aGiftGoesToACategoryOfGiftsOfTheOwnersSpending() {
    let income = CoreKit.Category(id: Self.id(61), kind: .income, name: "Подарки")
    #expect(
      BorrowedCardRules.giftCategory(categories: [income])
        == .create(nameKey: BorrowedCardRules.giftNameKey),
      "an income category of the same name is no category of spending")
    let live = CoreKit.Category(id: Self.id(62), kind: .expense, name: " gifts ")
    #expect(BorrowedCardRules.giftCategory(categories: [income, live]) == .existing(live.id))
    let archived = CoreKit.Category(
      id: Self.id(63), kind: .expense, name: "Подарки", archived: true)
    #expect(
      BorrowedCardRules.giftCategory(categories: [archived])
        == .revive(archived.id, parent: nil))
    let draft = BorrowedCardRules.giftDraft(
      transfer: transfer(from: own.id, to: papa.id, 700), categoryId: live.id)
    #expect(draft.kind == .expense)
    #expect(draft.paymentMethodId == own.id)
    #expect(draft.amount == AmountE4(whole: 700))
    #expect(draft.parts.first?.categoryId == live.id)
    #expect(draft.note == "на обед")
  }

  @Test func aRepaymentPaysTheOpenDebtToThePersonWhoseCardItIs() {
    func debt(
      _ number: Int, _ direction: DebtDirection, person: UUID?, name: String = "Долг",
      currency: CurrencyCode = .rub, closed: Bool = false
    ) -> Debt {
      Debt(
        id: Self.id(number), direction: direction, type: .loan, name: name, personId: person,
        currency: currency, closed: closed)
    }
    let person = Self.id(90)
    let debts = [
      debt(80, .owedToMe, person: person),
      debt(81, .iOwe, person: Self.id(91)),
      debt(82, .iOwe, person: person, closed: true),
      debt(83, .iOwe, person: person, currency: .usd),
      debt(84, .iOwe, person: person, name: "Б"),
      debt(85, .iOwe, person: person, name: "А"),
    ]
    #expect(
      BorrowedCardRules.debtToRepay(card: papa, currency: .rub, debts: debts)?.id == Self.id(85))
    #expect(
      BorrowedCardRules.debtToRepay(card: papa, currency: .usd, debts: debts)?.id == Self.id(83))
    #expect(BorrowedCardRules.debtToRepay(card: papa, currency: .eur, debts: debts) == nil)
    var unsaid = papa
    unsaid.borrowed?.personId = nil
    #expect(BorrowedCardRules.debtToRepay(card: unsaid, currency: .rub, debts: debts) == nil)
    #expect(BorrowedTransferPurpose.allCases == [.advance, .gift, .debtRepayment])
  }
}
