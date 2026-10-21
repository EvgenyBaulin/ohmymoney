import Foundation

/// Known names the parser can recognise in the entry line. The app fills it from the
/// database; the parser itself stays free of storage.
public struct ParserVocabulary: Hashable, Sendable {
  public struct Entry: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let aliases: [String]

    public init(id: UUID, name: String, aliases: [String] = []) {
      self.id = id
      self.name = name
      self.aliases = aliases
    }

    /// Every spelling this entry answers to, longest first so "кофе точка" wins over "кофе".
    public var spellings: [String] {
      ([name] + aliases)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
    }
  }

  public var people: [Entry]
  public var places: [Entry]
  public var paymentMethods: [Entry]
  public var events: [Entry]
  public var goals: [Entry]
  public var debts: [Entry]
  public var enabledCurrencies: [CurrencyCode]
  /// The live cards of the live accounts: a card read in the line names its account too.
  public var cards: [CardEntry]

  /// A card the line may name, with the account it belongs to.
  public struct CardEntry: Hashable, Sendable {
    public var entry: Entry
    public var accountId: UUID

    public init(entry: Entry, accountId: UUID) {
      self.entry = entry
      self.accountId = accountId
    }
  }

  public init(
    people: [Entry] = [], places: [Entry] = [], paymentMethods: [Entry] = [],
    events: [Entry] = [], goals: [Entry] = [], debts: [Entry] = [],
    enabledCurrencies: [CurrencyCode] = CurrencyCode.defaultEnabled, cards: [CardEntry] = []
  ) {
    self.people = people
    self.places = places
    self.paymentMethods = paymentMethods
    self.events = events
    self.goals = goals
    self.debts = debts
    self.enabledCurrencies = enabledCurrencies
    self.cards = cards
  }

  public static let empty = ParserVocabulary()
}

/// What a recognised piece of the entry line means. Used for highlighting and for tests.
public enum ParsedRole: String, Hashable, Sendable, CaseIterable {
  case amount
  case currency
  case date
  case kind
  case forWhom
  case person
  case place
  case event
  case paymentMethod
  case goal
  case debt
  case note
}

public struct ParsedToken: Hashable, Sendable {
  public let role: ParsedRole
  public let text: String

  public init(role: ParsedRole, text: String) {
    self.role = role
    self.text = text
  }
}

/// A transfer the line names: the transfer word and the accounts it found. A side the line
/// names with a word no account answers to is nil, with that word in `unknownName`: nothing is
/// written then without the transfer sheet.
public struct TransferReading: Hashable, Sendable {
  public var fromAccountId: UUID?
  public var fromCardId: UUID?
  public var toAccountId: UUID?
  public var toCardId: UUID?
  /// The word that stood where an account was expected and named none.
  public var unknownName: String?

  public init(
    fromAccountId: UUID? = nil, fromCardId: UUID? = nil, toAccountId: UUID? = nil,
    toCardId: UUID? = nil, unknownName: String? = nil
  ) {
    self.fromAccountId = fromAccountId
    self.fromCardId = fromCardId
    self.toAccountId = toAccountId
    self.toCardId = toCardId
    self.unknownName = unknownName
  }

  /// Both accounts are known and differ: the transfer can be written as it is (when their
  /// currencies agree — the app checks that).
  public var isComplete: Bool {
    fromAccountId != nil && toAccountId != nil && fromAccountId != toAccountId
  }
}

/// Whom the line says an expense was paid for: «за машу» — for her, to be given back;
/// «угостил машу» — a gift; «пополам с машей» — half each. A name the dictionary does not know
/// is `unknownName`; the app offers to add the person.
public struct PayingForReading: Hashable, Sendable {
  public enum Way: Hashable, Sendable {
    case forSomebody
    case gift
    case half
  }

  public var way: Way
  public var personId: UUID?
  public var unknownName: String?

  public init(way: Way, personId: UUID? = nil, unknownName: String? = nil) {
    self.way = way
    self.personId = personId
    self.unknownName = unknownName
  }
}

/// Result of reading one line of input. English and Russian are understood regardless of
/// the interface language. Anything not recognised becomes the note.
public struct ParsedInput: Hashable, Sendable {
  /// Why the line has no amount although a number was typed: a division by zero or garbage
  /// is never saved, it is a clear error instead.
  public enum AmountProblem: Hashable, Sendable {
    /// A formula divides by zero: `3000÷0`, `10 / 0`.
    case divisionByZero
    /// Larger than one amount may be (`AmountE4.inputLimit`).
    case tooLarge
    /// The formula comes out below zero; the sign of an operation comes from its kind.
    case negative
    /// A number or a formula that cannot be read: `12++`, `(1000+600`.
    case malformed
  }

  /// A day that was typed as a date but is not one of the calendar: the line is refused with
  /// the reason rather than saved with the word taken for a price.
  public enum DateProblem: Hashable, Sendable {
    /// No year has it: «31.09», «30.02», «2026-04-31». `written` is the word as typed.
    case noSuchDate(written: String)
    /// 29 February of a year without one — the year the rule of bare days gives, or the one
    /// typed.
    case notInYear(day: Int, month: Int, year: Int)
  }

  public var kind: TransactionKind
  public var amount: Decimal?
  /// The expression exactly as typed, kept when the amount was a formula.
  public var amountExpression: String?
  /// The amount as typed with every number in it written the way the app writes numbers:
  /// «1500,5» is «1,500.5», «1,500+2,50» is «1,500+2.50». Nil without an amount.
  public var amountCanonicalText: String?
  /// Set only while `amount` is nil: what went wrong with the number that was typed.
  public var amountProblem: AmountProblem?
  public var currency: CurrencyCode?
  public var date: DateOnly?
  public var forWhom: ForWhom?
  public var personId: UUID?
  public var placeId: UUID?
  public var eventId: UUID?
  public var paymentMethodId: UUID?
  public var goalId: UUID?
  public var debtId: UUID?
  /// A name that looked like a person but is not in the dictionary yet.
  public var unknownPersonName: String?
  /// A place written as "в <место>" / "at <place>" that is not in the dictionary yet.
  public var unknownPlaceName: String?
  /// The words that named `unknownPersonName`, the marker included, as typed: «для Пети».
  /// They leave the note like every word the parser read; the app gives them back to the
  /// note while nothing is made of the name, so nothing typed is lost.
  public var unknownPersonPhrase: String?
  /// The same for `unknownPlaceName`: «в Кофемании».
  public var unknownPlacePhrase: String?
  public var note: String
  public var tokens: [ParsedToken]
  /// The card the line named; `paymentMethodId` is then its account.
  public var cardId: UUID?
  /// Set when the line wrote a day the calendar does not have; `date` is nil then.
  public var dateProblem: DateProblem?
  /// Set when the line is a transfer between accounts — «перевод 5000 сбер т-банк» — and not
  /// an operation; `paymentMethodId` and `cardId` are then those of the account it leaves.
  public var transfer: TransferReading?
  /// «за машу», «пополам с машей», «угостил машу»: whom the expense was paid for, and how.
  public var payingFor: PayingForReading?
  /// «со счёта», «from account»: the line asks for no card — the money leaves the account
  /// itself, not its main card.
  public var withoutCard = false

  public init(
    kind: TransactionKind = .expense,
    amount: Decimal? = nil,
    amountExpression: String? = nil,
    amountCanonicalText: String? = nil,
    amountProblem: AmountProblem? = nil,
    currency: CurrencyCode? = nil,
    date: DateOnly? = nil,
    forWhom: ForWhom? = nil,
    personId: UUID? = nil,
    placeId: UUID? = nil,
    eventId: UUID? = nil,
    paymentMethodId: UUID? = nil,
    goalId: UUID? = nil,
    debtId: UUID? = nil,
    unknownPersonName: String? = nil,
    unknownPlaceName: String? = nil,
    unknownPersonPhrase: String? = nil,
    unknownPlacePhrase: String? = nil,
    note: String = "",
    tokens: [ParsedToken] = [],
    cardId: UUID? = nil,
    dateProblem: DateProblem? = nil
  ) {
    self.kind = kind
    self.amount = amount
    self.amountExpression = amountExpression
    self.amountCanonicalText = amountCanonicalText
    self.amountProblem = amountProblem
    self.currency = currency
    self.date = date
    self.forWhom = forWhom
    self.personId = personId
    self.placeId = placeId
    self.eventId = eventId
    self.paymentMethodId = paymentMethodId
    self.goalId = goalId
    self.debtId = debtId
    self.unknownPersonName = unknownPersonName
    self.unknownPlaceName = unknownPlaceName
    self.unknownPersonPhrase = unknownPersonPhrase
    self.unknownPlacePhrase = unknownPlacePhrase
    self.note = note
    self.tokens = tokens
    self.cardId = cardId
    self.dateProblem = dateProblem
  }

  /// Nothing can be saved without an amount, nor on a day the calendar does not have.
  public var isSaveable: Bool { amount != nil && dateProblem == nil }

  /// The amount as written, when what it comes to is worth showing at once, before Enter:
  /// a formula, a number not written the way the app writes numbers — «1500,5» is shown
  /// as 1,500.50, «2,5k» as 2,500 — and a number whose point may be taken for one between the
  /// thousands: «1.500» is 1.50. Any other number reads as itself.
  public var amountToPreview: String? {
    if let amountExpression { return amountExpression }
    guard amount != nil, let written = tokens.first(where: { $0.role == .amount })?.text,
      written != amountCanonicalText || TypedNumber.mayBeTakenForThousands(written)
    else { return nil }
    return written
  }
}
