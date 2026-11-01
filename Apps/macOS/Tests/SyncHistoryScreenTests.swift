import AppCore
import Foundation
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// What the screens of the journal of changes, the cashback advisor and the sync key show: the
/// tab «История» in words with the device and no hidden account named, the ceilings and the day
/// of the choice through the rules sheet, the month's choice and its rules, the lines of «Стоит
/// посмотреть» about cashback, the missed cashback, and the key in the keychain — in both
/// languages.
@MainActor
final class SyncHistoryScreenTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() async throws {
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    suites = []
  }

  private func defaults() throws -> UserDefaults {
    let suite = "ohmymoney.tests.synchistory.\(UUID().uuidString)"
    suites.append(suite)
    return try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func at(_ s: Int) -> SyncInstant {
    SyncInstant(String(format: "2026-11-01T12:%02d:%02dZ", s / 60, s % 60))!
  }

  // MARK: - History

  private let visible = UUID()
  private let hidden = UUID()

  private func historyText(_ environment: AppEnvironment, covered: Bool) -> OperationHistoryText {
    var names = OperationHistoryText.Names()
    let accounts = [visible: "Everyday", hidden: "Secret Savings"]
    names.account = { accounts[$0] }
    let language = environment.language
    let money = environment.money
    return OperationHistoryText(
      names: names, hiddenAccounts: covered ? [hidden] : [], ownDeviceId: "mac",
      text: { language($0, table: "SyncHistory") }, money: { money.exact($0, currency: $1) },
      moment: { environment.dates.moment($0) })
  }

  private func events() -> [HistoryEvent] {
    let records = [
      ChangeRecord(
        seq: 1, key: RecordKey(table: "transactions", uuid: "op"), op: .created, at: at(1),
        deviceId: "mac", deviceName: "",
        fields: [
          "note": .string("coffee"), "payment_method_id": .string(visible.uuidString),
          "amount_e4": .int(2_500_000),
        ]),
      ChangeRecord(
        seq: 2, key: RecordKey(table: "transactions", uuid: "op"), op: .updated, at: at(9),
        deviceId: "phone", deviceName: "iPhone",
        fields: [
          "note": .string("latte"), "payment_method_id": .string(hidden.uuidString),
          "amount_e4": .int(3_000_000), "amount_rub_e4": .int(3_000_000),
          "dedup_key": .string("x"), "posted_on": .string("2026-11-01"),
        ]),
    ]
    return ChangeHistory.events(forOperation: "op", records: records)
  }

  func testTheHistoryNamesTheDeviceTheFieldsAndNoHiddenAccount() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let rows = historyText(environment, covered: true).rows(events())
      XCTAssertEqual(rows.count, 2)
      XCTAssertTrue(rows[0].title.contains("iPhone"), rows[0].title)
      XCTAssertTrue(
        rows[1].title.contains(environment.language("history.device.this", table: "SyncHistory")))
      let lines = rows[0].lines.joined(separator: "\n")
      XCTAssertTrue(lines.contains("coffee") && lines.contains("latte"), lines)
      XCTAssertFalse(lines.contains("Secret Savings"), "\(choice): a covered account is not named")
      XCTAssertTrue(
        lines.contains(environment.language("history.hidden.account", table: "SyncHistory")), lines)
      // The rubles follow from the amount and are not said; the other unshown field is counted.
      XCTAssertEqual(rows[0].lines.count, 4, lines)
      XCTAssertFalse(rows[0].when.isEmpty)
      let revealed = historyText(environment, covered: false).rows(events())
      XCTAssertTrue(revealed[0].lines.joined().contains("Secret Savings"))
    }
  }

  func testEveryKeyOfTheNewCatalogIsThereInBothLanguages() {
    let keys =
      [
        "history.tab.details", "history.tab.history", "history.empty", "history.empty.dataSet",
        "history.kind.created", "history.kind.edited", "history.kind.deleted",
        "history.kind.restored", "history.device.this", "history.device.other",
        "history.part.added", "history.part.removed", "history.part.prefix", "history.more",
        "history.gone", "history.hidden.account", "history.hidden.card",
        "cashback.cap.rule", "cashback.cap.account", "cashback.cap.none", "cashback.cap.perMonth",
        "cashback.cap.unreadable", "cashback.choiceDay", "cashback.choiceDay.none",
        "cashback.choiceDay.day", "cashback.choiceDay.last", "cashback.choice.open",
        "cashback.choice.title", "cashback.choice.best", "cashback.choice.mapping",
        "cashback.missed.open", "cashback.missed.title", "cashback.missed.line",
        "recovery.page.title", "recovery.sheet.once", "recovery.key.make", "recovery.key.made",
      ] + OperationHistoryText.shownFields.map { "history.field.\($0)" } + CashbackNoteText.keys
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "SyncHistory"), key, "\(choice) \(key)")
      }
    }
  }

  // MARK: - Ceilings and the day of the choice

  func testTheRulesSheetCarriesTheCeilingsAndTheDay() {
    let account = UUID()
    let food = UUID()
    let rule = CashbackRule(
      accountId: account, categoryId: food, percent: CashbackPercent(e4: 50_000)!,
      monthlyCapE4: AmountE4(whole: 500))
    var draft = CashbackRulesDraft(
      holders: [.account(account)], accountId: account, rules: [rule],
      month: MonthKey(year: 2026, month: 11),
      settings: CashbackAccountSettings(monthlyCapE4: AmountE4(whole: 3_000), choiceDay: 5))
    XCTAssertEqual(draft.always.first?.capText, "500")
    XCTAssertEqual(draft.accountCapText, "3000")
    XCTAssertEqual(draft.rules?.first?.monthlyCapE4, AmountE4(whole: 500))
    var row = draft.always[0]
    row.capText = "abc"
    draft.update(row)
    XCTAssertNil(draft.rules, "a ceiling that does not read keeps «Сохранить» off")
    row.capText = ""
    draft.update(row)
    XCTAssertEqual(draft.rules?.first?.monthlyCapE4, AmountE4??.some(nil))
    draft.accountCapText = "1500"
    draft.settings.choiceDay = 31
    let settings = draft.settingsToSave
    XCTAssertEqual(settings?.monthlyCapE4, AmountE4(whole: 1_500))
    XCTAssertEqual(settings?.choiceDay, 31)
    let applied = settings?.applied(to: PaymentMethod(id: account, name: "Card"))
    XCTAssertEqual(applied?.cashbackMonthlyCapE4, AmountE4(whole: 1_500))
    XCTAssertEqual(applied?.cashbackChoiceDay, 31)
    draft.accountCapText = "-"
    XCTAssertNil(draft.settingsToSave)
  }

  func testANewCeilingAloneIsAChangeOfTheRule() {
    let old = CashbackRule(accountId: UUID(), percent: CashbackPercent(e4: 10_000)!)
    var new = old
    new.monthlyCapE4 = AmountE4(whole: 100)
    let diff = CashbackRules.diff(old: [old], new: [new])
    XCTAssertEqual(diff.upserts.first?.monthlyCapE4, AmountE4(whole: 100))
    XCTAssertEqual(diff.upserts.first?.id, old.id)
  }

  // MARK: - The month's choice

  func testTheMonthsChoiceWritesTheBanksTableAndTheRules() throws {
    let bank = UUID()
    let account = UUID()
    let food = UUID()
    let cafes = UUID()
    let november = MonthKey(year: 2026, month: 11)
    var draft = CashbackChoiceDraft(
      accountId: account, bankId: bank, month: november, offers: [],
      mappings: [BankCategoryMapping(bankId: bank, label: "Супермаркеты", categoryId: food)])
    XCTAssertEqual(draft.pick, 3)
    draft.rows = [
      .init(label: "Супермаркеты", percentText: "5"),
      .init(label: "Кафе", percentText: "7"),
      .init(label: "АЗС", percentText: "x"),
    ]
    XCTAssertFalse(draft.canSave)
    draft.rows[2].percentText = "3"
    XCTAssertTrue(draft.canSave)
    draft.mapping[BankCategoryMapping.normalized("Кафе")] = cafes
    draft.pick = 2
    let tree = CategoryTree([
      CoreKit.Category(id: food, kind: .expense, name: "Food"),
      CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
    ])
    let spending = [food: AmountE4(whole: 10_000), cafes: AmountE4(whole: 2_000)]
    let best = try XCTUnwrap(draft.best(spending: spending, tree: tree, accountCap: nil).first)
    // 500 + 140 beats anything with the fuel nobody maps.
    XCTAssertEqual(best.expectedRub, AmountE4(whole: 640))
    draft.take(best)
    XCTAssertEqual(draft.offers.filter(\.chosen).map(\.label).sorted(), ["Кафе", "Супермаркеты"])
    XCTAssertEqual(Set(draft.mappings.map(\.label)), ["Супермаркеты", "Кафе"])
    let standing = CashbackRule(accountId: account, percent: CashbackPercent(e4: 10_000)!)
    let old = CashbackRule(
      accountId: account, categoryId: UUID(), month: november, percent: CashbackPercent(e4: 1)!)
    let rules = draft.rules(replacing: [standing, old])
    XCTAssertTrue(rules.contains(standing), "the standing rate stays")
    XCTAssertFalse(rules.contains(old), "the month's earlier choice goes")
    XCTAssertEqual(
      Set(rules.filter { $0.month == november }.compactMap(\.categoryId)), [food, cafes])
    draft.rows[2].chosen = true
    XCTAssertEqual(draft.unmappedChosen, ["АЗС"])
  }

  func testTheLinesOfCashbackInBothLanguages() {
    let account = UUID()
    let card = UUID()
    let place = UUID()
    let category = UUID()
    let notes: [CashbackNote] = [
      .choose(CashbackChoiceDue(accountId: account, month: MonthKey(year: 2026, month: 11))),
      .payHere(
        PayHereHint(
          month: MonthKey(year: 2026, month: 11), placeId: place, categoryId: category,
          best: CashbackCandidate(holder: .card(card), accountId: account),
          bestPercent: CashbackPercent(e4: 50_000)!, usual: nil, usualPercent: .zero,
          gainRub: AmountE4(whole: 240))),
      .trap(
        CashbackTrap(
          month: MonthKey(year: 2026, month: 11), categoryId: category,
          spentRub: AmountE4(whole: 3_000), cashbackRub: AmountE4(whole: 150),
          usualRub: AmountE4(whole: 1_000))),
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let names = [account: "T-Bank", card: "Black"]
      let labels = [place: "Corner shop", category: "Pharmacy"]
      for note in notes {
        let text = CashbackNoteText.text(note, accounts: names, labels: labels, environment)
        XCTAssertFalse(text.contains("%@"), text)
        switch note {
        case .choose: XCTAssertTrue(text.contains("T-Bank"), text)
        case .payHere: XCTAssertTrue(text.contains("Corner shop") && text.contains("Black"), text)
        case .trap: XCTAssertTrue(text.contains("Pharmacy"), text)
        }
        XCTAssertFalse(CashbackNoteText.symbol(note).isEmpty)
      }
      XCTAssertEqual(WorthALookNoteText.actions(.cashback(notes[0])), [.chooseCashback, .done])
      XCTAssertEqual(WorthALookNoteText.actions(.cashback(notes[2])), [.done])
      XCTAssertNotEqual(
        environment.language(
          WorthALookNoteText.Action.chooseCashback.key,
          table: WorthALookNoteText.Action.chooseCashback.table),
        WorthALookNoteText.Action.chooseCashback.key)
    }
  }

  func testACoveredAccountTakesItsCashbackLinesAway() {
    let secret = UUID()
    var account = PaymentMethod(id: secret, name: "Secret Savings")
    account.hidden = true
    let ledger = Ledger(dataset: Dataset(paymentMethods: [account]), calendar: .utc)
    let hiddenOps = HiddenOperations(accounts: HiddenAccounts(ids: [secret]), cards: [])
    let note = WorthALookNote.cashback(
      .choose(CashbackChoiceDue(accountId: secret, month: MonthKey(year: 2026, month: 11))))
    XCTAssertTrue(WorthALookCover.hides(note, hidden: hiddenOps, ledger: ledger))
    let trap = WorthALookNote.cashback(
      .trap(
        CashbackTrap(
          month: MonthKey(year: 2026, month: 11), categoryId: UUID(), spentRub: .zero,
          cashbackRub: .zero, usualRub: .zero)))
    XCTAssertFalse(WorthALookCover.hides(trap, hidden: hiddenOps, ledger: ledger))
  }

  func testMissedCashbackOfAnEmptyBookSaysNothingIsMissed() {
    let ledger = Ledger(dataset: Dataset(), calendar: .utc)
    let model = MissedCashbackModel.build(
      ledger: ledger, today: DateOnly(year: 2026, month: 11, day: 2), hidden: [])
    XCTAssertTrue(model.rows.isEmpty)
    XCTAssertEqual(model.totalRub, .zero)
  }

  // MARK: - The sync key

  func testTheKeyIsMadeOnceAndItsSheetShownOnce() throws {
    let store = InMemorySyncKeyStore()
    let defaults = try defaults()
    let (key, created) = try store.keyCreatingIfNeeded()
    XCTAssertTrue(created)
    XCTAssertEqual(try store.keyCreatingIfNeeded().key, key)
    XCTAssertFalse(try store.keyCreatingIfNeeded().created)
    XCTAssertFalse(RecoverySheetMark.wasShown(key, in: defaults))
    RecoverySheetMark.markShown(key, in: defaults)
    XCTAssertTrue(RecoverySheetMark.wasShown(key, in: defaults))
    XCTAssertFalse(RecoverySheetMark.wasShown(SyncKey.generate(), in: defaults))
    // The mark is the fingerprint, never the key.
    let stored = try XCTUnwrap(defaults.string(forKey: RecoverySheetMark.key))
    XCTAssertFalse(key.recoveryWords.contains { stored.contains($0) })
    XCTAssertEqual(stored.count, 8)
  }

  func testTheQRCodeHoldsTheWords() throws {
    let key = SyncKey.generate()
    let image = try XCTUnwrap(RecoveryQR.image(for: key.recoveryWords))
    XCTAssertGreaterThan(image.width, 100)
  }
}
