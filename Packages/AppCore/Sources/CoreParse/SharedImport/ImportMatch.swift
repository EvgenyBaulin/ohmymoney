import CoreKit
import Foundation

/// The file a purchase was read from, kept with the operation it ends up on.
public struct RecognizedFile: Hashable, Sendable {
  public var data: Data
  public var fileName: String
  public var mediaType: String?

  public init(data: Data, fileName: String, mediaType: String? = nil) {
    self.data = data
    self.fileName = fileName
    self.mediaType = mediaType
  }
}

/// What a recogniser read off a screenshot of a bank app or a receipt, after the owner checked
/// it: the sum, the day, perhaps the time, the shop, and which account paid. The reading itself
/// (text recognition on the device, a PDF's text) fills it; matching and writing go by it alone.
public struct RecognizedPurchase: Hashable, Sendable {
  public var kind: TransactionKind
  public var amount: AmountE4
  public var currency: CurrencyCode
  public var day: DateOnly
  /// The time the picture shows; `nil` when it shows none.
  public var time: TimeOfDay?
  /// The shop or the payee as the picture names it.
  public var merchant: String?
  /// The merchant category code, when a bank shows it.
  public var mcc: String?
  /// The last four digits of the card the picture names.
  public var cardLast4: String?
  /// The account that paid: chosen by the owner or named by the card's digits
  /// (`ImportMatch.account(forCard:cards:)`). Nothing is matched without it.
  public var accountID: UUID?
  public var file: RecognizedFile?

  public init(
    kind: TransactionKind = .expense, amount: AmountE4, currency: CurrencyCode = .rub,
    day: DateOnly, time: TimeOfDay? = nil, merchant: String? = nil, mcc: String? = nil,
    cardLast4: String? = nil, accountID: UUID? = nil, file: RecognizedFile? = nil
  ) {
    self.kind = kind
    self.amount = amount
    self.currency = currency
    self.day = day
    self.time = time
    self.merchant = merchant
    self.mcc = mcc
    self.cardLast4 = cardLast4
    self.accountID = accountID
    self.file = file
  }
}

/// What the import offers for a recognised purchase.
public enum ImportMatchOutcome: Hashable, Sendable {
  /// No account is known yet: the owner picks one before anything is looked for or written.
  case needsAccount
  /// This very file is already attached to an operation: the purchase was imported before.
  case alreadyAttached(ScreenshotCandidate)
  /// One operation fits: «Найдена похожая операция» — supplement it, or say it is another
  /// purchase. `isSimilar`: it fits only within the receipt's tolerances, not exactly.
  case one(ScreenshotCandidate, isSimilar: Bool)
  /// Several fit, ordered by how close their time is; none is chosen for the owner.
  case several([ScreenshotCandidate], isSimilar: Bool)
  /// Nothing fits: a new operation.
  case none

  /// The operations the owner may pick from.
  public var offered: [ScreenshotCandidate] {
    switch self {
    case .needsAccount, .none: []
    case .alreadyAttached(let holder): [holder]
    case .one(let candidate, _): [candidate]
    case .several(let list, _): list
    }
  }
}

/// What the import offers, and what a new operation would have to be confirmed against.
public struct ImportProposal: Hashable, Sendable {
  public var outcome: ImportMatchOutcome
  /// Offered operations a new one would most likely repeat: the one already holding the file,
  /// every exact match, and a similar one whose note names the same shop.
  public var duplicates: Set<UUID>
  /// Operations of the same kind, sum and day on another account. They are not offered (the
  /// account is part of a match), but a new operation is written only after «всё равно
  /// создать»: the owner may have written the purchase on the wrong card.
  public var otherAccount: [ScreenshotCandidate]

  public init(
    outcome: ImportMatchOutcome, duplicates: Set<UUID> = [],
    otherAccount: [ScreenshotCandidate] = []
  ) {
    self.outcome = outcome
    self.duplicates = duplicates
    self.otherAccount = otherAccount
  }

  /// «Это другая покупка» asks «точно создать ещё одну?» first.
  public var needsDuplicateConfirmation: Bool { !duplicates.isEmpty }
  /// A new operation asks «Похоже на операцию на другом счёте — всё равно создать?» first.
  public var needsOtherAccountConfirmation: Bool { !otherAccount.isEmpty }
}

/// What the owner pressed.
public enum ImportChoice: Hashable, Sendable {
  /// «Дополнить эту операцию».
  case supplement(UUID)
  /// «Это другая покупка — создать новую»; `confirmedDuplicate` is the second yes a probable
  /// duplicate asks for, `confirmedOtherAccount` the yes to «Похоже на операцию на другом
  /// счёте — всё равно создать?».
  case createNew(confirmedDuplicate: Bool, confirmedOtherAccount: Bool = false)
}

/// What to do about the choice.
public enum ImportStep: Hashable, Sendable {
  /// Fill the operation's empty fields and attach the file (`ImportSupplement`).
  case supplement(UUID)
  /// Nothing to write: show the operation (a transfer, or the one already holding the file).
  case open(UUID)
  /// Write a new operation.
  case create
}

public enum ImportRefusal: Error, Hashable, Sendable {
  /// The choice names an operation that was not offered.
  case notOffered
  /// No account is known.
  case needsAccount
  /// A new operation over a probable duplicate needs the second yes.
  case duplicateNeedsConfirmation
  /// A new operation while the same sum and day stand on another account needs a yes.
  case otherAccountNeedsConfirmation
}

public enum ImportMatch {
  /// The account the card's last four digits name: the one live card with them. Two accounts
  /// with the same digits, or none, name nothing — the owner picks.
  public static func account(forCard last4: String?, cards: [PaymentCard]) -> UUID? {
    guard let digits = last4.map({ String($0.filter(\.isNumber).suffix(4)) }), digits.count == 4
    else { return nil }
    let accounts = Set(cards.filter { !$0.archived && $0.last4 == digits }.map(\.accountId))
    return accounts.count == 1 ? accounts.first : nil
  }

  /// Matches a purchase against the operations of the books (`ScreenshotMatch.candidates`):
  /// first the operation already holding the very file (`holdingFile`, ids from the
  /// attachments), then exact matches by account, sum and day, then — without one — the
  /// receipt's tolerances, marked similar. Nothing is ever chosen or merged for the owner.
  public static func propose(
    _ item: RecognizedPurchase, among candidates: [ScreenshotCandidate],
    holdingFile: Set<UUID> = [], calendar: CalendarContext
  ) -> ImportProposal {
    if let holder = candidates.filter({ holdingFile.contains($0.id) && !$0.isTransfer })
      .min(by: { $0.occurredAt < $1.occurredAt })
    {
      return ImportProposal(outcome: .alreadyAttached(holder), duplicates: [holder.id])
    }
    guard let account = item.accountID else { return ImportProposal(outcome: .needsAccount) }
    let proposal = ScreenshotMatch.propose(
      amount: item.amount, kind: item.kind, currency: item.currency, accountID: account,
      day: item.day, time: item.time, among: candidates, calendar: calendar)
    // A transfer has both sides on the list of candidates; one id is one offer.
    var seen = Set<UUID>()
    let matches = proposal.matches.filter { seen.insert($0.id).inserted }
    let outcome: ImportMatchOutcome =
      switch matches.count {
      case 0: .none
      case 1: .one(matches[0], isSimilar: proposal.isSimilar)
      default: .several(matches, isSimilar: proposal.isSimilar)
      }
    let duplicates = matches.filter {
      !proposal.isSimilar || isSameMerchant(item.merchant, $0.note)
    }.map(\.id)
    let elsewhere = candidates.filter {
      $0.accountID != account && !$0.isTransfer && $0.kind == item.kind
        && $0.amount(in: item.currency) == item.amount
        && calendar.day(of: $0.occurredAt, recordedIn: $0.timeZoneID) == item.day
    }.sorted {
      $0.occurredAt != $1.occurredAt
        ? $0.occurredAt < $1.occurredAt : $0.id.uuidString < $1.id.uuidString
    }
    return ImportProposal(
      outcome: outcome, duplicates: Set(duplicates), otherAccount: elsewhere)
  }

  /// Whether the shop a picture names is the one an operation's note names: the same words
  /// regardless of case, «ё» and spaces, one holding the other («Пятёрочка» and «пятерочка у
  /// дома»). Fewer than three letters say nothing.
  public static func isSameMerchant(_ merchant: String?, _ note: String?) -> Bool {
    func plain(_ text: String?) -> String {
      (text ?? "").lowercased()
        .replacingOccurrences(of: "ё", with: "е")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let shop = plain(merchant)
    let written = plain(note)
    guard min(shop.count, written.count) >= 3 else { return false }
    return written.contains(shop) || shop.contains(written)
  }

  /// Checks the owner's choice against what was offered. A new operation asks the questions in
  /// order: first about a probable duplicate, then about the same purchase on another account.
  public static func resolve(
    _ choice: ImportChoice, for proposal: ImportProposal
  ) -> Result<ImportStep, ImportRefusal> {
    let outcome = proposal.outcome
    if case .needsAccount = outcome { return .failure(.needsAccount) }
    switch choice {
    case .createNew(let duplicate, let otherAccount):
      if proposal.needsDuplicateConfirmation && !duplicate {
        return .failure(.duplicateNeedsConfirmation)
      }
      if proposal.needsOtherAccountConfirmation && !otherAccount {
        return .failure(.otherAccountNeedsConfirmation)
      }
      return .success(.create)
    case .supplement(let id):
      guard let chosen = outcome.offered.first(where: { $0.id == id }) else {
        return .failure(.notOffered)
      }
      if case .alreadyAttached = outcome { return .success(.open(id)) }
      return .success(chosen.isTransfer ? .open(id) : .supplement(id))
    }
  }
}
