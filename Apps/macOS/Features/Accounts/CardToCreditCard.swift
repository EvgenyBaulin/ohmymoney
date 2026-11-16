import AppCore
import AppDatabase
import Foundation

/// «Сделать кредиткой»: what the sheet asks and how it reads the answers, before anything is
/// written. The terms are the ones of the account editor (`CreditDraft`); the card's past is a
/// choice of three — all of it goes with the card, only what is of a day and later, or none of
/// it — and the credit card takes the card's name unless the books refuse that one.
struct CardToCreditCardDraft: Equatable {
  /// What the operations the card already paid do.
  enum Past: String, CaseIterable, Hashable, Sendable {
    case all
    case fromDate
    case none
  }

  /// Why the card did not become a credit card. Nothing is written then.
  enum Refusal: Equatable {
    case terms(CreditTermsIssue)
    case conversion(CreditCardConversionIssue)
  }

  var credit: CreditDraft
  /// «Все» by default: a card kept under a debit account by mistake was a credit card all along.
  var past: Past = .all
  /// The first day that goes with the card in `.fromDate`.
  var fromDate: Date
  /// What the credit card is called; empty — as the card.
  var name = ""
  /// The books refused the card's own name: the field for another one shows.
  var asksForName = false
  var refusal: Refusal?

  init(today: Date) {
    var credit = CreditDraft(nil)
    credit.isOn = true
    self.credit = credit
    fromDate = today
  }

  /// What `past` and the date mean to the books, the day read in the calendar of the Mac.
  func pastOperations(calendar: CalendarContext) -> CardPastOperations {
    switch past {
    case .all: .all
    case .none: .none
    case .fromDate: .onAndAfter(calendar.day(of: fromDate))
    }
  }

  /// The plan of the conversion of `card`, or the refusal, which stays in `refusal` for the
  /// sheet to say; a refused name opens the field for another one.
  mutating func attempt(
    converting card: PaymentCard, cards: [PaymentCard], accounts: [PaymentMethod],
    calendar: CalendarContext
  ) -> CreditCardConversionPlan? {
    let terms: CreditCardTerms
    switch credit.terms() {
    case .success(let typed?): terms = typed
    case .success(nil): return fail(.conversion(.terms))
    case .failure(let issue): return fail(.terms(issue))
    }
    let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = CreditCardConversion.plan(
      converting: card.id, terms: terms, past: pastOperations(calendar: calendar),
      name: typedName.isEmpty ? nil : typedName, cards: cards, accounts: accounts)
    switch result {
    case .success(let plan):
      refusal = nil
      return plan
    case .failure(let issue):
      if case .name = issue { asksForName = true }
      return fail(.conversion(issue))
    }
  }

  private mutating func fail(_ reason: Refusal) -> CreditCardConversionPlan? {
    refusal = reason
    return nil
  }
}

extension AccountActions {
  /// «Сделать кредиткой»: one change, one step of ⌘Z. The card, its credit account and what
  /// moves with them are written together; the entry line learns the names at once.
  func convert(_ plan: CreditCardConversionPlan) -> AccountActionOutcome {
    apply(PlanningChange.cardConversion(plan, at: environment.now()))
  }

  /// A new credit card of `bank`: an account of its kind card under the bank and the group the
  /// bank's other accounts are in, in the main currency, with its first card and the terms the
  /// owner typed. Named as typed, or «Кредитная карта», numbered when it is taken.
  func addCreditCard(
    to bank: Bank, terms: CreditCardTerms, named typed: String = "", books: AccountBooks,
    accountId: UUID = UUID(), cardId: UUID = UUID()
  ) -> (id: UUID, outcome: AccountActionOutcome) {
    guard CreditCardConversion.termsFit(terms) else { return (accountId, .refused(.credit(.limit))) }
    let accounts = all
    let given = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    let name =
      given.isEmpty
      ? Self.freeName(
        environment.language("account.creditCard.defaultName", table: AccountText.table),
        accounts: accounts, cards: cards)
      : given
    let sibling = ordered(accounts).first { $0.bankId == bank.id && !$0.archived }
    let account = PaymentMethod(
      id: accountId, name: name, kind: .card, currency: environment.defaultCurrency,
      groupId: sibling?.groupId, bankId: bank.id, credit: terms)
    let outcome = save(account, previous: nil, books: books, firstCardId: cardId)
    return (accountId, outcome)
  }

  /// `base`, then «base 2», «base 3»… until no live account or card is called so.
  static func freeName(_ base: String, accounts: [PaymentMethod], cards: [PaymentCard]) -> String {
    var number = 1
    var candidate = base
    while AccountRules.nameConflict(
      PaymentMethod(name: candidate), accounts: accounts, cards: cards) != nil
    {
      number += 1
      candidate = "\(base) \(number)"
    }
    return candidate
  }
}

/// «+ → Кредитная карта»: the terms and the name as typed. Nothing is made until a limit reads.
struct NewCreditCardDraft: Equatable {
  var credit: CreditDraft
  var name = ""

  init() {
    var credit = CreditDraft(nil)
    credit.isOn = true
    self.credit = credit
  }

  /// The terms, or why they cannot be kept; an empty limit is `.limit`.
  func terms() -> Result<CreditCardTerms, CreditTermsIssue> {
    switch credit.terms() {
    case .success(let terms?):
      return CreditCardConversion.termsFit(terms) ? .success(terms) : .failure(.limit)
    case .success(nil): return .failure(.limit)
    case .failure(let issue): return .failure(issue)
    }
  }

  /// «Создать» is enabled once the terms read.
  var canCreate: Bool {
    if case .success = terms() { return true }
    return false
  }
}

/// The two choices of the «+» of a bank, in the order the menu shows them.
enum BankPlusChoice: String, CaseIterable, Hashable, Sendable {
  case debitCard
  case creditCard

  var key: String {
    switch self {
    case .debitCard: "tree.plus.debitCard"
    case .creditCard: "tree.plus.creditCard"
    }
  }

  var identifier: String { "accounts.tree.plus.\(rawValue)" }
}

extension AccountText {
  /// What a refusal of «Сделать кредиткой» says.
  static func message(
    _ refusal: CardToCreditCardDraft.Refusal, _ environment: AppEnvironment
  )
    -> String
  {
    switch refusal {
    case .terms(let issue): return message(.credit(issue), environment)
    case .conversion(let issue):
      switch issue {
      case .name(.nameTaken): return message(.nameTaken, environment)
      case .name(.otherNameTaken(let name)): return message(.otherNameTaken(name), environment)
      case .name(.nameTakenByCard(let name)): return message(.nameTakenByCard(name), environment)
      case .terms: return message(.credit(.limit), environment)
      case .emptyName: return message(.emptyName, environment)
      case .notFound: return environment.language("card.toCredit.refusal.notFound", table: table)
      case .archived: return environment.language("card.toCredit.refusal.archived", table: table)
      case .alreadyCreditCard:
        return environment.language("card.toCredit.refusal.already", table: table)
      case .borrowed: return environment.language("card.toCredit.refusal.borrowed", table: table)
      case .noBank: return environment.language("card.toCredit.refusal.noBank", table: table)
      }
    }
  }
}
