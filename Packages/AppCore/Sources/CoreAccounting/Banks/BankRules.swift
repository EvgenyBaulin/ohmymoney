import CoreKit
import Foundation

/// What is wrong with a bank about to be saved.
public enum BankIssue: Hashable, Sendable {
  case emptyName
  /// A live bank — the one with this id — is already called so.
  case nameTaken(UUID)
}

/// What a new bank starts with: the bank, its first account and the card of that account. One
/// write, one step of ⌘Z.
public struct BankKit: Hashable, Sendable {
  public var bank: Bank
  public var account: PaymentMethod
  /// `nil` for an account of a kind that is not paid from with a card (`CardRules.startingCard`).
  public var card: PaymentCard?

  public init(bank: Bank, account: PaymentMethod, card: PaymentCard?) {
    self.bank = bank
    self.account = account
    self.card = card
  }
}

/// The bank a new account goes under.
public struct BankChoice: Hashable, Sendable {
  public var bank: Bank
  /// The bank does not exist yet: it is written with the account.
  public var isNew: Bool

  public init(bank: Bank, isNew: Bool) {
    self.bank = bank
    self.isNew = isNew
  }
}

/// The rules of the banks that do not need the database: what a bank may be called, the order of
/// the lists, what is under a bank, and what a new bank starts with.
///
/// A bank owns no money. «Bank → account → card» is a way of naming and filing: the balances,
/// the operations and the counts are the accounts', and an account keeps its own name, so the
/// entry line reads what it read before.
public enum BankRules {
  // MARK: Names

  /// What is wrong with `bank` about to be saved, `others` being every bank — archived ones too.
  /// Names are compared the way the entry line reads them (`NameKey`). A live bank has a name of
  /// its own among the live banks; one in the archive keeps the name it had, and meets the live
  /// ones again when it comes back.
  public static func validate(_ bank: Bank, among others: [Bank]) -> [BankIssue] {
    var issues: [BankIssue] = []
    let name = NameKey.fold(bank.name)
    if name.isEmpty { issues.append(.emptyName) }
    guard !bank.archived, !name.isEmpty else { return issues }
    if let rival = others.first(where: {
      $0.id != bank.id && !$0.archived && NameKey.fold($0.name) == name
    }) {
      issues.append(.nameTaken(rival.id))
    }
    return issues
  }

  /// The live bank called `name`, if any.
  public static func live(named name: String, among banks: [Bank]) -> Bank? {
    let folded = NameKey.fold(name)
    guard !folded.isEmpty else { return nil }
    return banks.first { !$0.archived && NameKey.fold($0.name) == folded }
  }

  // MARK: Order

  /// The live banks in the order of the lists: by `sort` — 0 for every bank the app writes, so
  /// alphabetical — then by name in `locale`, then by id.
  public static func ordered(_ banks: [Bank], locale: Locale = .current) -> [Bank] {
    banks.filter { !$0.archived }.sorted { precedes($0, $1, locale: locale) }
  }

  /// The order of the lists for any banks.
  public static func precedes(_ left: Bank, _ right: Bank, locale: Locale) -> Bool {
    if left.sort != right.sort { return left.sort < right.sort }
    switch left.name.compare(right.name, options: [.caseInsensitive], range: nil, locale: locale) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return left.id.uuidString < right.id.uuidString
    }
  }

  /// The place of a new bank: after every other once the banks have been given places,
  /// otherwise alphabetical like the rest.
  public static func sortForNewBank(among banks: [Bank]) -> Int {
    let highest = banks.map(\.sort).max() ?? 0
    return highest > 0 ? highest + 1 : 0
  }

  // MARK: What is under a bank

  /// The accounts that belong to the bank, archived ones too.
  public static func accounts(under bank: UUID, among accounts: [PaymentMethod]) -> [PaymentMethod]
  {
    accounts.filter { $0.bankId == bank }
  }

  /// A bank goes to the archive once every account under it has — a bank with a live account is
  /// in use.
  public static func canBeArchived(_ bank: UUID, among accounts: [PaymentMethod]) -> Bool {
    !accounts.contains { $0.bankId == bank && !$0.archived }
  }

  /// A bank is deleted only with no account under it, archived ones included: an archived
  /// account still holds the history of its operations.
  public static func canBeDeleted(_ bank: UUID, among accounts: [PaymentMethod]) -> Bool {
    !accounts.contains { $0.bankId == bank }
  }

  // MARK: A new bank

  /// What a bank starts with: the bank, an account called like it — of the kind `kind`, a card
  /// by default, in `currency` — and the card of that account (`CardRules.startingCard`), also
  /// called like it. `accounts` and `banks` are all there are: the new bank goes after the live
  /// ones once the banks have places, and the first account of a book is the main one.
  /// Nothing is checked here: the name may be taken (`validate`).
  public static func startingKit(
    named name: String, kind: PaymentMethodKind = .card, currency: CurrencyCode?,
    accounts: [PaymentMethod], banks: [Bank]
  ) -> BankKit {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let liveAccounts = accounts.filter { !$0.archived }
    let bank = Bank(
      name: name, sort: sortForNewBank(among: banks.filter { !$0.archived }))
    let account = PaymentMethod(
      name: name, kind: kind, currency: currency, isDefault: liveAccounts.isEmpty,
      sort: AccountRules.sortForNewAccount(among: liveAccounts), bankId: bank.id)
    return BankKit(bank: bank, account: account, card: CardRules.startingCard(for: account))
  }

  /// The bank a new account called `name` goes under when the owner chose none: the live bank
  /// of that name, else a new one of its own — an account is never left without a bank.
  public static func bank(forNewAccountNamed name: String, among banks: [Bank]) -> BankChoice {
    if let existing = live(named: name, among: banks) {
      return BankChoice(bank: existing, isNew: false)
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return BankChoice(
      bank: Bank(name: trimmed, sort: sortForNewBank(among: banks.filter { !$0.archived })),
      isNew: true)
  }
}
