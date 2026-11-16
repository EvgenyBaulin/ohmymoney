import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

// Synthetic data only.

@Suite("A card becomes a credit card of its own")
struct CardToCreditCardTests {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "CC000000-0000-0000-0000-%012d", number))!
  }

  let bank = Self.id(90)
  let group = Self.id(91)
  var debit: PaymentMethod {
    PaymentMethod(
      id: Self.id(1), name: "Т-Банк", currency: .rub, isDefault: true, groupId: group, sort: 3,
      otherCurrencies: [.usd], bankId: bank, cashbackRounding: .standard, cushion: true,
      mainCardId: Self.id(11), hidden: false, cashbackMonthlyCapE4: AmountE4(whole: 5_000),
      cashbackChoiceDay: 25, piggy: true)
  }
  var black: PaymentCard {
    PaymentCard(
      id: Self.id(11), accountId: Self.id(1), name: "Кредитная карта", aliases: ["Платинум"],
      sort: 2, last4: "1234")
  }
  var plain: PaymentCard { PaymentCard(id: Self.id(12), accountId: Self.id(1), name: "Блэк") }
  var sber: PaymentMethod {
    PaymentMethod(id: Self.id(2), name: "Сбер", currency: .rub, bankId: Self.id(92))
  }
  let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
    purchaseRate: Decimal(string: "29.9"))

  func plan(
    _ past: CardPastOperations = .all, name: String? = nil, accounts: [PaymentMethod]? = nil,
    cards: [PaymentCard]? = nil, terms: CreditCardTerms? = nil
  ) -> Result<CreditCardConversionPlan, CreditCardConversionIssue> {
    CreditCardConversion.plan(
      converting: Self.id(11), terms: terms ?? self.terms, past: past, name: name,
      cards: cards ?? [black, plain], accounts: accounts ?? [debit, sber],
      accountId: Self.id(5), leftCardId: Self.id(15))
  }

  @Test func theCreditCardIsANewAccountOfTheSameBankAndGroupWithTheCardAsItsMainOne() throws {
    let worked = try plan().get()
    let account = worked.account
    #expect(account.id == Self.id(5) && account.name == "Кредитная карта")
    #expect(account.bankId == bank && account.groupId == group && account.sort == 3)
    #expect(account.kind == .card && account.currency == .rub && account.otherCurrencies == [.usd])
    #expect(account.credit == terms && account.isCreditCard)
    #expect(account.mainCardId == Self.id(11))
    #expect(account.cashbackChoiceDay == 25 && account.cashbackRounding == debit.cashbackRounding)
    // The former account's own things stay with it.
    #expect(!account.isDefault && !account.cushion && !account.piggy)
    #expect(account.cashbackMonthlyCapE4 == nil && account.interest == nil)
    // The card keeps everything it is known by and moves.
    #expect(worked.card.id == black.id && worked.card.accountId == account.id)
    #expect(worked.card.aliases == ["Платинум"] && worked.card.last4 == "1234")
    // The former account lets go of it as its main card, and stays the main account.
    #expect(worked.former.mainCardId == nil && worked.former.isDefault)
    #expect(worked.accountsToReconcile == [Self.id(1), Self.id(5)])
  }

  @Test func theLeftCardIsArchivedOnTheFormerAccountAndCalledAsTheCardWas() throws {
    let left = try plan().get().leftCard
    #expect(left.id == Self.id(15) && left.accountId == Self.id(1) && left.archived)
    #expect(left.name == "Кредитная карта" && left.aliases == ["Платинум"])
    #expect(left.last4 == nil)
  }

  @Test func anotherMainCardOfTheFormerAccountStaysMain() throws {
    var account = debit
    account.mainCardId = Self.id(12)
    let worked = try plan(accounts: [account, sber]).get()
    #expect(worked.former.mainCardId == Self.id(12))
  }

  @Test func aNameTypedIsTrimmedAndAClashIsRefused() throws {
    #expect(try plan(name: "  Платинум Т  ").get().account.name == "Платинум Т")
    #expect(plan(name: "   ").failure == .emptyName)
    #expect(plan(name: "сбер").failure == .name(.nameTaken))
    #expect(plan(name: "Блэк").failure == .name(.nameTakenByCard("Блэк")))
    // A card called as its account: the credit card needs another name.
    let same = PaymentCard(id: Self.id(11), accountId: Self.id(1), name: "Т-Банк")
    #expect(plan(cards: [same]).failure == .name(.nameTaken))
  }

  @Test func whatCannotBeConvertedIsRefused() {
    var archivedCard = black
    archivedCard.archived = true
    #expect(plan(cards: [archivedCard]).failure == .archived)
    var shut = debit
    shut.archived = true
    #expect(plan(accounts: [shut]).failure == .archived)
    var credit = debit
    credit.credit = terms
    #expect(plan(accounts: [credit]).failure == .alreadyCreditCard)
    var borrowed = debit
    borrowed.borrowed = BorrowedCardTerms()
    #expect(plan(accounts: [borrowed]).failure == .borrowed)
    var loose = debit
    loose.bankId = nil
    #expect(plan(accounts: [loose]).failure == .noBank)
    #expect(plan(accounts: [sber]).failure == .notFound)
    #expect(
      CreditCardConversion.plan(
        converting: Self.id(99), terms: terms, cards: [black], accounts: [debit]
      ).failure == .notFound)
  }

  @Test func termsTheBooksCannotKeepAreRefused() {
    #expect(plan(terms: CreditCardTerms(limitE4: .zero)).failure == .terms)
    #expect(
      plan(
        terms: CreditCardTerms(limitE4: AmountE4(whole: 1), grace: .statement(day: 32, payDays: 1))
      )
      .failure == .terms)
    #expect(
      plan(
        terms: CreditCardTerms(limitE4: AmountE4(whole: 1), grace: .statement(day: 1, payDays: 61))
      )
      .failure == .terms)
    #expect(
      plan(terms: CreditCardTerms(limitE4: AmountE4(whole: 1), grace: .fromPurchase(days: 367)))
        .failure == .terms)
    #expect(
      plan(terms: CreditCardTerms(limitE4: AmountE4(whole: 1), minFloorE4: AmountE4(raw: -1)))
        .failure == .terms)
    #expect(
      CreditCardConversion.termsFit(
        CreditCardTerms(limitE4: AmountE4(whole: 1), grace: .fromPurchase(days: 366))))
  }

  @Test func theActionIsOfferedForALiveCardOfAnOwnDebitAccount() {
    #expect(CreditCardConversion.offered(for: black, accounts: [debit]))
    var credit = debit
    credit.credit = terms
    #expect(!CreditCardConversion.offered(for: black, accounts: [credit]))
    var borrowed = debit
    borrowed.borrowed = BorrowedCardTerms()
    #expect(!CreditCardConversion.offered(for: black, accounts: [borrowed]))
    var archived = black
    archived.archived = true
    #expect(!CreditCardConversion.offered(for: archived, accounts: [debit]))
    #expect(!CreditCardConversion.offered(for: black, accounts: [sber]))
  }

  // MARK: Which operations go

  func operation(
    _ number: Int, at iso: String, zone: String? = nil, card: UUID? = id(11),
    externalId: String? = nil
  ) -> Transaction {
    let instant = ISO8601DateFormatter().date(from: iso)!
    return Transaction(
      id: Self.id(100 + number), kind: .expense, occurredAt: instant,
      amountE4: AmountE4(whole: 100), paymentMethodId: Self.id(1), externalId: externalId,
      cardId: card, timeZoneId: zone)
  }

  @Test func allTakesEveryOperationOfTheCardAndNoneTakesNothing() throws {
    let moscow = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    let all = try plan(.all).get()
    let none = try plan(.none).get()
    let paid = operation(1, at: "2026-01-10T09:00:00Z")
    #expect(all.moves(paid, calendar: moscow))
    #expect(!none.moves(paid, calendar: moscow))
    // An operation of another card, or of the account itself, never goes.
    #expect(
      !all.moves(operation(2, at: "2026-01-10T09:00:00Z", card: Self.id(12)), calendar: moscow))
    #expect(!all.moves(operation(3, at: "2026-01-10T09:00:00Z", card: nil), calendar: moscow))
  }

  @Test func onAndAfterGoesByTheDayEachOperationWasRecordedOn() throws {
    // The Mac is in Moscow; the boundary day is 1 March.
    let moscow = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    let worked = try plan(.onAndAfter(DateOnly(year: 2026, month: 3, day: 1))).get()
    // 28 February 23:30 in Moscow: before the day.
    #expect(
      !worked.moves(
        operation(1, at: "2026-02-28T20:30:00Z", zone: "Europe/Moscow"), calendar: moscow))
    // 1 March 00:10 in Moscow: on the day.
    #expect(
      worked.moves(
        operation(2, at: "2026-02-28T21:10:00Z", zone: "Europe/Moscow"), calendar: moscow))
    // The same instant written in Los Angeles is still 28 February there: it stays.
    #expect(
      !worked.moves(
        operation(3, at: "2026-02-28T21:10:00Z", zone: "America/Los_Angeles"), calendar: moscow))
    // 1 March 08:00 in Auckland is 28 February in Moscow, yet the operation's own day is 1 March.
    #expect(
      worked.moves(
        operation(4, at: "2026-02-28T19:00:00Z", zone: "Pacific/Auckland"), calendar: moscow))
  }

  @Test func theFeeOfATransferAndTheDifferenceOfACountStayWithTheirRows() throws {
    let utc = CalendarContext.utc
    let worked = try plan(.all).get()
    let fee = operation(
      1, at: "2026-01-10T09:00:00Z",
      externalId: OperationLink.transferFee(Self.id(70)).externalId)
    let count = operation(
      2, at: "2026-01-10T09:00:00Z",
      externalId: OperationLink.reconciliation(Self.id(71)).externalId)
    let paid = operation(
      3, at: "2026-01-10T09:00:00Z",
      externalId: OperationLink.scheduled(
        paymentId: Self.id(72), due: DateOnly(year: 2026, month: 1, day: 10)
      )
      .externalId)
    #expect(!worked.moves(fee, calendar: utc))
    #expect(!worked.moves(count, calendar: utc))
    #expect(worked.moves(paid, calendar: utc))
  }
}

extension Result {
  fileprivate var failure: Failure? {
    if case .failure(let issue) = self { return issue }
    return nil
  }
}
