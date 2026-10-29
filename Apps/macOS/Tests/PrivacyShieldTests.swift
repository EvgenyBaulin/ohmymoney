import AppCore
import AppDatabase
import CoreKit
import XCTest

@testable import OhMyMoney

/// Answers every request with the answer a test set, and counts the requests.
private final class FakeAuthenticator: LockAuthenticator, @unchecked Sendable {
  private let lock = NSLock()
  private var _answer: LockAuthentication
  private var _requests = 0

  init(_ answer: LockAuthentication) { _answer = answer }

  var answer: LockAuthentication {
    get { lock.withLock { _answer } }
    set { lock.withLock { _answer = newValue } }
  }
  var requests: Int { lock.withLock { _requests } }

  func authenticate(reason: String) async -> LockAuthentication {
    lock.withLock {
      _requests += 1
      return _answer
    }
  }
}

/// The hidden accounts and «Только просмотр»: who may see and change what, and what the journal of
/// openings is told.
@MainActor
final class PrivacyShieldTests: XCTestCase {
  private let hiddenAccount: PaymentMethod = {
    var account = PaymentMethod(name: "Secret Savings")
    account.hidden = true
    return account
  }()
  private let openAccount = PaymentMethod(name: "Sber Main")

  private func shield(
    _ answer: LockAuthentication = .passed
  ) -> (PrivacyShield, FakeAuthenticator, EventBox) {
    let authenticator = FakeAuthenticator(answer)
    let shield = PrivacyShield(authenticator: authenticator)
    let events = EventBox()
    shield.journal = { events.list.append($0) }
    return (shield, authenticator, events)
  }

  final class EventBox { var list: [PrivacyJournalEntry.Event] = [] }

  // MARK: The hidden accounts

  func testTheAppStartsCoveredAndCoversWhatTheDataSaysIsHidden() {
    let (shield, _, _) = shield()
    shield.learn(accounts: [hiddenAccount, openAccount], cards: [])
    XCTAssertEqual(shield.visibility, .covered)
    XCTAssertTrue(shield.hasHiddenAccounts)
    XCTAssertEqual(shield.covering.ids, [hiddenAccount.id])
    XCTAssertEqual(shield.offered([hiddenAccount, openAccount]).map(\.id), [openAccount.id])
  }

  func testTheCardsOfAHiddenAccountAreCoveredToo() {
    let (shield, _, _) = shield()
    let card = PaymentCard(accountId: hiddenAccount.id, name: "Secret card")
    shield.learn(accounts: [hiddenAccount], cards: [card])
    XCTAssertEqual(shield.coveredCardIds, [card.id])
  }

  func testShowingThemAsksForProofAndIsJournaled() async {
    let (shield, authenticator, events) = shield(.passed)
    shield.learn(accounts: [hiddenAccount], cards: [])
    let shown = await shield.reveal(reason: "test")
    XCTAssertTrue(shown)
    XCTAssertEqual(authenticator.requests, 1)
    XCTAssertEqual(shield.visibility, .revealed)
    XCTAssertTrue(shield.covering.isEmpty)
    XCTAssertEqual(shield.offered([hiddenAccount, openAccount]).count, 2)
    XCTAssertEqual(events.list, [.hiddenShown])
  }

  func testARefusedOrCancelledProofShowsNothing() async {
    for answer in [LockAuthentication.failed, .cancelled] {
      let (shield, _, events) = shield(answer)
      shield.learn(accounts: [hiddenAccount], cards: [])
      let shown = await shield.reveal(reason: "test")
      XCTAssertFalse(shown)
      XCTAssertEqual(shield.visibility, .covered)
      XCTAssertEqual(shield.lastRefusal, answer)
      XCTAssertTrue(events.list.isEmpty)
    }
  }

  func testWithNothingHiddenThereIsNothingToShow() async {
    let (shield, authenticator, _) = shield()
    shield.learn(accounts: [openAccount], cards: [])
    let shown = await shield.reveal(reason: "test")
    XCTAssertFalse(shown)
    XCTAssertEqual(authenticator.requests, 0)
  }

  func testCoveringAgainTakesThemBackAndCostsNoProof() async {
    let (shield, authenticator, _) = shield()
    shield.learn(accounts: [hiddenAccount], cards: [])
    _ = await shield.reveal(reason: "test")
    shield.cover()
    XCTAssertEqual(shield.visibility, .covered)
    XCTAssertEqual(shield.covering.ids, [hiddenAccount.id])
    XCTAssertEqual(authenticator.requests, 1)
  }

  func testWhatTheListsLeaveOutChangesTheRevision() async {
    let (shield, _, _) = shield()
    let before = shield.revision
    shield.learn(accounts: [hiddenAccount], cards: [])
    XCTAssertGreaterThan(shield.revision, before)
    let learned = shield.revision
    shield.learn(accounts: [hiddenAccount], cards: [])
    XCTAssertEqual(shield.revision, learned, "the same data changes nothing")
    _ = await shield.reveal(reason: "test")
    XCTAssertGreaterThan(shield.revision, learned)
  }

  func testAMacThatCanProveNothingLetsTheOwnerThrough() async {
    let (shield, _, _) = shield(.unavailable)
    shield.learn(accounts: [hiddenAccount], cards: [])
    let shown = await shield.reveal(reason: "test")
    XCTAssertTrue(shown)
  }

  // MARK: The lock

  func testTheLockCoveringAndUncoveringTellTheApp() async {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: FakeAuthenticator(.passed))
    var covered = 0
    var unlocked: [PrivacyJournalEntry.UnlockMethod] = []
    lock.onLocked = { covered += 1 }
    lock.onUnlocked = { unlocked.append($0) }
    let enabled = await lock.enable(reason: "test")
    XCTAssertTrue(enabled)
    lock.lock(because: .menu)
    XCTAssertEqual(covered, 1)
    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)
    XCTAssertEqual(unlocked, [.touchID])
    // A lock that is already on says nothing twice.
    lock.lock(because: .menu)
    lock.lock(because: .idle)
    XCTAssertEqual(covered, 2)
  }

  // MARK: Read-only

  func testEveryActionIsRefusedWhileReadOnly() {
    let (shield, _, events) = shield()
    for action in ReadOnlyAction.allCases { XCTAssertTrue(shield.allows(action)) }
    var persisted: [Bool] = []
    var switched: [Bool] = []
    shield.persistReadOnly = { persisted.append($0) }
    shield.onReadOnlyChange = { switched.append($0) }
    shield.turnReadOnlyOn()
    for action in ReadOnlyAction.allCases { XCTAssertFalse(shield.allows(action), "\(action)") }
    XCTAssertTrue(shield.isReadOnly)
    XCTAssertEqual(persisted, [true])
    XCTAssertEqual(switched, [true])
    XCTAssertEqual(events.list, [.readOnlyOn])
  }

  func testLeavingNeedsProofAndRefusedProofKeepsTheMode() async {
    let (shield, authenticator, events) = shield(.failed)
    shield.turnReadOnlyOn()
    for answer in [LockAuthentication.failed, .cancelled] {
      authenticator.answer = answer
      let left = await shield.leaveReadOnly(reason: "test")
      XCTAssertFalse(left)
      XCTAssertTrue(shield.isReadOnly)
    }
    XCTAssertEqual(events.list, [.readOnlyOn])
    authenticator.answer = .passed
    var switched: [Bool] = []
    shield.onReadOnlyChange = { switched.append($0) }
    let left = await shield.leaveReadOnly(reason: "test")
    XCTAssertTrue(left)
    XCTAssertFalse(shield.isReadOnly)
    XCTAssertEqual(switched, [false])
    XCTAssertEqual(events.list, [.readOnlyOn, .readOnlyOff])
  }

  func testTheSavedChoiceIsTakenUpWithoutAJournalLine() {
    let (shield, _, events) = shield()
    shield.adopt(readOnly: true)
    XCTAssertTrue(shield.isReadOnly)
    XCTAssertTrue(events.list.isEmpty)
  }

  func testTheFlowsWithoutAnEnvironmentAskTheGate() {
    ReadOnlyGate.isOn = false
    XCTAssertFalse(ReadOnlyGate.isOn)
    ReadOnlyGate.isOn = true
    XCTAssertTrue(ReadOnlyGate.isOn)
    ReadOnlyGate.isOn = false
  }

  func testTheStoreRefusesEveryWriteAndUndoWhileReadOnly() {
    let store = TransactionsStore()
    XCTAssertFalse(store.refuses("apply", #fileID))
    store.isReadOnly = { true }
    XCTAssertTrue(store.refuses("apply", #fileID))
    XCTAssertFalse(store.canUndo)
  }

  // MARK: The amounts while the screen is watched

  func testTheAmountsHideThemselvesWhileWatchedAndComeBackWithoutTouchingTheChoice() {
    let amounts = AmountPrivacy(defaults: nil)
    XCTAssertFalse(amounts.isHidingNow)
    amounts.capture = [.mirroring]
    XCTAssertTrue(amounts.isHidingNow)
    XCTAssertEqual(amounts.decision.reason, .capture)
    XCTAssertFalse(amounts.hidesAmounts, "the owner's own switch is not touched")
    amounts.capture = []
    XCTAssertFalse(amounts.isHidingNow)
  }

  func testTheSettingTurnsTheAutomaticHidingOff() {
    let amounts = AmountPrivacy(defaults: nil)
    amounts.autoHideOnCapture = false
    amounts.capture = [.recording]
    XCTAssertFalse(amounts.isHidingNow)
    amounts.hidesAmounts = true
    XCTAssertTrue(amounts.isHidingNow)
    XCTAssertEqual(amounts.decision.reason, .manual)
  }

  // MARK: The lists

  private func ledgerOfTwoAccounts() -> (Ledger, hiddenOp: UUID, openOp: UUID, toHidden: UUID, between: UUID, secret: PaymentMethod) {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let secret = hiddenAccount
    let other = PaymentMethod(name: "Other secret", currency: .rub)
    var hiddenOther = other
    hiddenOther.hidden = true
    let hiddenOp = UUID()
    let openOp = UUID()
    func entry(_ id: UUID, on account: UUID) -> TransactionEntry {
      TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 10),
          paymentMethodId: account),
        parts: [TransactionPart(transactionId: id, categoryId: food.id, amountE4: AmountE4(whole: 10))])
    }
    func transfer(_ from: UUID, _ to: UUID) -> Transfer {
      Transfer(
        occurredAt: Date(), fromAccountId: from, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: 5), toAccountId: to, toCurrency: .rub,
        toAmountE4: AmountE4(whole: 5))
    }
    let toHidden = transfer(openAccount.id, secret.id)
    let between = transfer(secret.id, hiddenOther.id)
    var dataset = Dataset()
    dataset.categories = [food]
    dataset.paymentMethods = [openAccount, secret, hiddenOther]
    dataset.entries = [entry(hiddenOp, on: secret.id), entry(openOp, on: openAccount.id)]
    dataset.transfers = [toHidden, between]
    return (
      Ledger(dataset: dataset, calendar: .system), hiddenOp, openOp, toHidden.id, between.id,
      secret
    )
  }

  func testTheTableLeavesOutTheHiddenOperationsAndNamesNoHiddenAccount() {
    let (ledger, hiddenOp, openOp, toHidden, between, secret) = ledgerOfTwoAccounts()
    var covered = EntryFilter.none
    covered.hiddenAccountIds = ledger.dataset.paymentMethods.filter(\.hidden).map(\.id).reduce(into: []) { $0.insert($1) }
    let listing = TransactionListing.build(matching: covered, in: ledger)
    XCTAssertTrue(listing.visibleIds.contains(openOp))
    XCTAssertFalse(listing.visibleIds.contains(hiddenOp))
    XCTAssertTrue(listing.visibleIds.contains(toHidden))
    XCTAssertFalse(listing.visibleIds.contains(between), "between two hidden accounts: nothing")
    let rows = listing.sections.flatMap(\.rows).compactMap(\.transfer)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.caption, .toHidden)
    XCTAssertEqual(rows.first?.accounts, "")
    XCTAssertFalse(rows.first?.to.contains(secret.name) ?? true)
  }

  func testRevealedTheTableShowsEverything() {
    let (ledger, hiddenOp, _, toHidden, between, _) = ledgerOfTwoAccounts()
    let listing = TransactionListing.build(matching: .none, in: ledger)
    XCTAssertTrue(listing.visibleIds.contains(hiddenOp))
    XCTAssertTrue(listing.visibleIds.contains(toHidden))
    XCTAssertTrue(listing.visibleIds.contains(between))
  }

  func testTheSearchNeverFindsATransferByTheNameOfAHiddenAccount() {
    let (ledger, _, _, toHidden, _, secret) = ledgerOfTwoAccounts()
    var covered = EntryFilter.none
    covered.text = secret.name
    covered.hiddenAccountIds = [secret.id]
    XCTAssertFalse(TransactionListing.build(matching: covered, in: ledger).visibleIds.contains(toHidden))
    var shown = EntryFilter.none
    shown.text = secret.name
    XCTAssertTrue(TransactionListing.build(matching: shown, in: ledger).visibleIds.contains(toHidden))
  }

  func testThePresentedSnapshotHasNoHiddenAccountAndTheSameTotals() {
    let dataset: Dataset = {
      var d = Dataset()
      d.paymentMethods = [openAccount, hiddenAccount]
      return d
    }()
    let whole = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: DateOnly(year: 2026, month: 10, day: 29),
      context: SnapshotContext(), version: DataVersion(load: 0))
    let hidden = HiddenAccounts(accounts: dataset.paymentMethods)
    let presented = whole.presented(hiding: hidden)
    XCTAssertEqual(presented.dataset.paymentMethods.map(\.id), [openAccount.id])
    XCTAssertEqual(whole.dataset.paymentMethods.count, 2, "the pipeline's snapshot is whole")
    XCTAssertEqual(whole.ledger.dataset.paymentMethods.count, 2)
    XCTAssertEqual(
      presented.planning.accounts.inSummaryTotalRub, whole.planning.accounts.inSummaryTotalRub)
    let lines = presented.planning.accounts.sections.flatMap(\.accounts)
    XCTAssertFalse(lines.contains { $0.account.id == hiddenAccount.id })
    // Nothing hidden: the snapshot is returned as it is.
    let same = whole.presented(hiding: HiddenAccounts(ids: [UUID]()))
    XCTAssertEqual(same.dataset.paymentMethods.count, 2)
    XCTAssertNil(same.coveredAccounts)
  }

  // MARK: Words

  private static func word(_ language: String, _ key: String, table: String) -> String? {
    guard
      let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    else { return nil }
    let text = bundle.localizedString(forKey: key, value: "\u{0}", table: table)
    return text == "\u{0}" ? nil : text
  }

  func testEveryWordIsInBothLanguages() {
    let keys = [
      "privacy.transfer.toHidden", "privacy.transfer.fromHidden", "privacy.transfer.betweenHidden",
      "privacy.partHidden", "privacy.hidden.show", "privacy.hidden.hide", "privacy.reveal.reason",
      "privacy.readOnly.leave.reason", "privacy.readOnly.banner", "privacy.readOnly.exit",
      "privacy.readOnly.menu.on", "privacy.readOnly.menu.off", "account.editor.hidden",
      "account.editor.hiddenHint",
    ]
    for key in keys {
      for language in ["en", "ru"] {
        let text = Self.word(language, key, table: "PrivacyScreens")
        XCTAssertNotNil(text, "\(key) in \(language)")
        XCTAssertFalse(text?.isEmpty ?? true)
      }
    }
    for key in ["archive.import.readOnly", "backups.restore.readOnly"] {
      for language in ["en", "ru"] {
        XCTAssertNotNil(Self.word(language, key, table: "Settings"), "\(key) in \(language)")
      }
    }
  }

  func testTheTransferCaptionsAreTheCoresWordsAndNameNobody() {
    for caption in [HiddenAccounts.TransferCaption.toHidden, .fromHidden, .betweenHidden] {
      XCTAssertEqual(Self.word("ru", caption.key, table: "PrivacyScreens"), caption.russian)
      XCTAssertEqual(Self.word("en", caption.key, table: "PrivacyScreens"), caption.english)
    }
  }
}
