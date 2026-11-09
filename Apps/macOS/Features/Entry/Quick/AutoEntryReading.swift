import AppCore
import Foundation

/// A text a bank sent, read against the owner's books: the operation, the line it makes, the
/// card's account and whether it is hidden, whether the books have it already, and how the
/// balance the bank reports agrees with the account's. The same on the Mac and on the phone;
/// what is then done with it — written, offered, announced — is the caller's.
@MainActor
struct AutoEntryReading {
  let message: BankMessage
  /// The line the entry line reads back as this operation. For a card of a hidden account it
  /// does not name the card, so a draft that waits in the list never shows it.
  let line: String
  /// The shop as the owner's list or his corrections name it.
  let placeName: String?
  let accountId: UUID?
  let isHidden: Bool
  /// The books have an operation of the same day, kind and amount.
  let isInBooks: Bool
  /// The one operation typed by hand on the card's account that the text is about, when there
  /// is exactly one: what the owner made of the shop is learned from it.
  let handTyped: TransactionEntry?
  /// What the books say is on the card's account in the currency of the reported balance.
  private let ledgerBalance: AmountE4?
  private let isCredit: Bool

  /// `nil` when the text is not a bank's.
  init?(_ text: String, environment: AppEnvironment, snapshot: DataSnapshot) {
    let dataset = snapshot.dataset
    let today = environment.today
    // An account without a bank reads as a bank of its own name.
    let ownBanks =
      dataset.banks.filter { !$0.archived }.map(\.name)
      + dataset.paymentMethods.filter { $0.bankId == nil && !$0.archived }.map(\.name)
    guard let message = BankTextParser().parse(text, today: today, ownBanks: ownBanks) else {
      return nil
    }
    let names = AutoEntryLearning.names(environment)
    let places = environment.vocabulary.places
    let parser = InputLineParser(
      vocabulary: environment.vocabulary, calendar: environment.calendar,
      catalog: environment.currencyCatalog)
    let learned = BankTextLearning.memory(environment)
    let offer = QuickBank.offer(
      for: message, cards: dataset.cards, places: places, parser: parser, today: today,
      names: names, learned: learned, accounts: dataset.paymentMethods)
    let accountId = offer.card?.accountId
    let isHidden = HiddenAccounts(accounts: dataset.paymentMethods).isHidden(accountId)
    let shown = QuickBank.shown(
      message, account: accountId, names: names, learned: learned,
      accounts: dataset.paymentMethods, places: places)
    let place = shown.merchant.flatMap { BankMerchants.resolve($0, places: places) }
    self.message = message
    self.placeName = place?.name
    self.line = isHidden ? shown.suggestedLine(merchantName: place?.name) : offer.line
    self.accountId = accountId
    self.isHidden = isHidden
    if let accountId {
      let day = message.day ?? today
      self.handTyped = AutoEntryMemory.handTyped(
        for: message, account: accountId, on: day, entries: dataset.entries,
        dayOf: { environment.calendar.day(of: $0.occurredAt, recordedIn: $0.timeZoneId) })
    } else {
      self.handTyped = nil
    }
    self.isInBooks =
      QuickBank.candidates(
        [BankListItem(source: "", message: message)], entries: dataset.entries,
        calendar: environment.calendar, today: today
      ).first?.isDuplicate ?? false
    let account = accountId.flatMap { id in dataset.paymentMethods.first { $0.id == id } }
    isCredit = account?.credit != nil
    if let accountId, let reported = message.balance {
      ledgerBalance =
        snapshot.planning.accounts.balances[
          BalanceKey(accountId: accountId, currency: reported.currency)]?.amountE4
    } else {
      ledgerBalance = nil
    }
  }

  /// A text about an operation the owner typed by hand teaches what its shop means — for the
  /// next texts and the statements of the same account alike (`BankTextMemory`). Says whether
  /// it taught.
  @discardableResult
  func teach(environment: AppEnvironment, accounts: [PaymentMethod]) -> Bool {
    guard let handTyped, let accountId else { return false }
    return BankTextLearning.matched(
      message: message, account: accountId, entry: handTyped, accounts: accounts,
      environment: environment)
  }

  /// The fields kept of the text, never the text.
  func suggestion(receivedAt: Date) -> AutoEntrySuggestion {
    AutoEntrySuggestion(message: message, line: line, receivedAt: receivedAt)
  }

  /// The balance the bank reports against the books; `includesOperation` — the operation is in
  /// the books already.
  func mismatch(includesOperation: Bool) -> BankBalanceCheck.Mismatch? {
    guard accountId != nil else { return nil }
    return BankBalanceCheck.compare(
      reported: message.balance, ledger: ledgerBalance, includesOperation: includesOperation,
      operation: message.operation, amount: message.money, isCredit: isCredit)
  }

  /// The same operation waits in «Запишу потом» already — offered from the SMS when the push
  /// comes, or before a restart.
  func isWaiting(environment: AppEnvironment, defaults: UserDefaults = .standard) -> Bool {
    let drafts = SettingsDraftStore(settings: environment.settings).load()
    return AutoEntryLearning.waitingFingerprints(drafts, defaults: defaults)
      .contains(suggestion(receivedAt: Date()).fingerprint)
  }

  /// The line of a draft: with the day of the operation («12.09»), so a draft finished the next
  /// day still lands on the day the bank wrote about.
  func draftLine(on day: DateOnly) -> String {
    line + " " + String(format: "%02d.%02d", day.day, day.month)
  }

  /// Keeps the line in «Запишу потом», remembering the shop to learn from when the owner
  /// finishes it; the id of the draft, or `nil` when it did not land.
  func keepDraft(
    environment: AppEnvironment, now: Date, defaults: UserDefaults = .standard
  ) -> UUID? {
    let store = SettingsDraftStore(settings: environment.settings)
    let day = message.day ?? environment.calendar.day(of: now)
    guard let draft = PendingDraft(text: draftLine(on: day), createdAt: now),
      store.save(store.load() + [draft])
    else { return nil }
    AutoEntryLearning.remember(
      draft: draft.id, merchant: message.merchant,
      fingerprint: suggestion(receivedAt: now).fingerprint, defaults: defaults)
    NotificationCenter.default.post(name: .draftsChanged, object: nil)
    return draft.id
  }
}

/// The words of auto entry, in the interface language.
@MainActor
struct AutoEntryWords {
  nonisolated static let table = "AutoEntry"

  let environment: AppEnvironment

  func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), locale: environment.language.locale, arguments: arguments)
  }

  /// Amounts written in full: a notice says one only when it may.
  private var money: MoneyFormatter {
    MoneyFormatter(
      locale: environment.language.locale, hidesAmounts: false,
      currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
  }

  /// «Кофемания 450 ₽», or «Кофемания» without the amount; the kind of the operation when the
  /// text names no shop («Снятие наличных 3 000 ₽»).
  func subject(
    name: String?, operation: BankOperation, money amount: Money, saysAmount: Bool
  ) -> String {
    let title = name ?? t("autoEntry.operation.\(operation.rawValue)")
    guard saysAmount else { return title }
    return "\(title) \(money.exact(amount.amount, currency: amount.currency))"
  }

  func mismatch(_ mismatch: BankBalanceCheck.Mismatch, saysAmount: Bool) -> String {
    guard saysAmount else { return t("autoEntry.notify.mismatchHidden") }
    return f(
      "autoEntry.notify.mismatch",
      money.exact(mismatch.bank.amount, currency: mismatch.bank.currency),
      money.exact(mismatch.ledger.amount, currency: mismatch.ledger.currency))
  }
}
