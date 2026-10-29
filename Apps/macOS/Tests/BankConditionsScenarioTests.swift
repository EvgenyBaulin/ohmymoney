import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The conditions of a bank are typed in the editor of an account or a card, kept in the database,
/// read back with the rest of the data, and said in both languages: the limits of a month, the
/// balance to keep (asked about before the line is written), the card that ends, the money
/// forgotten, the insurance of a bank. The sums themselves are the core's (`BankConditionsTests`).
@MainActor
final class BankConditionsScenarioTests: AccountsScenarioDatabaseCase {
  // MARK: The form

  func testTheDraftReadsTheTypedSumsAndAnEmptyFieldIsACondtionNotSaid() throws {
    var draft = BankConditionsDraft()
    XCTAssertTrue(draft.isValid)
    draft.freeCash = "100 000"
    draft.freeSbp = "50000"
    draft.serviceSpend = "10000"
    draft.minBalance = "50 000"
    draft.note = "  до 31 декабря  "
    let account = UUID()
    let result = try draft.conditions(accountId: account, cardId: nil, currency: .rub).get()
    XCTAssertEqual(result.freeCashE4, rub(100_000))
    XCTAssertEqual(result.freeSbpE4, rub(50_000))
    XCTAssertNil(result.freeInterbankE4, "empty is not said, never zero")
    XCTAssertEqual(result.serviceFreeSpendE4, rub(10_000))
    XCTAssertNil(result.serviceFreeBalanceE4)
    XCTAssertEqual(result.minBalanceE4, rub(50_000))
    XCTAssertEqual(result.note, "до 31 декабря")
    XCTAssertFalse(result.isEmpty)
    XCTAssertTrue(
      try BankConditionsDraft().conditions(accountId: account, cardId: nil, currency: .rub).get()
        .isEmpty)
  }

  func testASumThatDoesNotReadOrIsNegativeIsRefused() {
    for bad in ["abc", "-5", "12 к"] {
      var draft = BankConditionsDraft()
      draft.freeCash = bad
      XCTAssertFalse(draft.isValid, bad)
      XCTAssertThrowsError(
        try draft.conditions(accountId: UUID(), cardId: nil, currency: .rub).get(), bad)
    }
  }

  func testTheDraftOfSavedConditionsShowsThemAsTyped() throws {
    let saved = BankConditions(
      accountId: UUID(), freeCashE4: rub(100_000), serviceFreeBalanceE4: rub(30_000),
      minBalanceE4: AmountE4(raw: 505_000_000))
    let draft = BankConditionsDraft(saved)
    XCTAssertEqual(draft.id, saved.id)
    XCTAssertEqual(draft.freeCash, CreditDraft.text(rub(100_000)))
    XCTAssertEqual(draft.minBalance, CreditDraft.text(AmountE4(raw: 505_000_000)))
    XCTAssertEqual(draft.freeSbp, "")
    XCTAssertEqual(
      try draft.conditions(accountId: saved.accountId, cardId: nil, currency: .rub).get(), saved)
  }

  // MARK: The database

  func testConditionsAreKeptReadBackAndLoadedWithTheData() async throws {
    let account = try await make(PaymentMethod(name: "Главный", isDefault: true))
    var draft = BankConditionsDraft()
    draft.freeCash = "100000"
    draft.minBalance = "50000"
    let row = try draft.conditions(accountId: account.id, cardId: nil, currency: .rub).get()
    XCTAssertTrue(BankConditionsStore.write(row, environment))
    XCTAssertEqual(BankConditionsStore.read(account: account.id, environment), row)
    let stack = try XCTUnwrap(environment.stack)
    var dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(dataset.bankData.conditions, [row])
    XCTAssertEqual(dataset.bankData.settings, .standard)
    // Typed empty, the row of the product goes.
    XCTAssertTrue(
      BankConditionsStore.write(BankConditions(id: row.id, accountId: account.id), environment))
    XCTAssertNil(BankConditionsStore.read(account: account.id, environment))
    dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertTrue(dataset.bankData.conditions.isEmpty)
  }

  func testTheConditionsOfACardAreItsOwnAndTheCardKeepsItsExpiry() async throws {
    let account = try await make(PaymentMethod(name: "Главный", isDefault: true))
    let card = PaymentCard(accountId: account.id, name: "Visa")
    XCTAssertEqual(cardActions.save(card, previous: nil), .done)
    var draft = CardDraft(nil)
    draft.name = "Visa"
    draft.expiresOn = MonthKey(year: 2028, month: 5)
    let saved = draft.card(previous: card, accountId: account.id)
    XCTAssertEqual(saved.expiresOn, MonthKey(year: 2028, month: 5))
    XCTAssertEqual(cardActions.save(saved, previous: card), .done)
    XCTAssertEqual(
      cardActions.cards.first { $0.id == card.id }?.expiresOn, MonthKey(year: 2028, month: 5))
    XCTAssertNil(CardDraft(card).expiresOn)
    XCTAssertEqual(CardDraft(saved).expiresOn, MonthKey(year: 2028, month: 5))

    var conditions = BankConditionsDraft()
    conditions.serviceSpend = "5000"
    let row = try conditions.conditions(accountId: account.id, cardId: card.id, currency: .rub)
      .get()
    XCTAssertTrue(BankConditionsStore.write(row, environment))
    XCTAssertEqual(BankConditionsStore.read(account: account.id, card: card.id, environment), row)
    XCTAssertNil(BankConditionsStore.read(account: account.id, environment), "not the account's")
  }

  func testTakingAMovementOutOfTheLimitIsOneChangeOfOneSettingAndComesBack() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let movement = UUID()
    let outcome = accounts.setLimitOff(movement, off: true, current: .standard)
    XCTAssertEqual(outcome, .done)
    let stack = try XCTUnwrap(environment.stack)
    var dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(dataset.bankData.settings.limitOff, [movement])
    XCTAssertEqual(
      accounts.setLimitOff(movement, off: false, current: dataset.bankData.settings), .done)
    dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertTrue(dataset.bankData.settings.limitOff.isEmpty)
  }

  func testTheReportOfTheLoadedDataCountsCashTakenOutAgainstTheLimit() async throws {
    let main = try await make(
      PaymentMethod(name: "Главный", isDefault: true), openings: [.rub: rub(200_000)])
    let cash = try await make(PaymentMethod(name: "Кошелёк", kind: .cash))
    var draft = BankConditionsDraft()
    draft.freeCash = "100000"
    XCTAssertTrue(
      BankConditionsStore.write(
        try draft.conditions(accountId: main.id, cardId: nil, currency: .rub).get(), environment))
    let outcome = try await transfer(from: main, to: cash, sent: 85_000)
    XCTAssertEqual(outcome, .done)
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let ledger = Ledger(dataset: dataset, calendar: environment.calendar)
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: moment, calendar: environment.calendar, rubPerUnit: [:],
      localeIdentifier: "en")
    let report = BankReport.build(
      ledger: ledger, accounts: snapshot, today: today, rubPerUnit: [:])
    let line = try XCTUnwrap(report.limits(of: main.id).first)
    XCTAssertEqual(line.usedE4, rub(85_000))
    XCTAssertEqual(
      report.notes(),
      [.limitNear(accountId: main.id, kind: .cash, leftE4: rub(15_000), currency: .rub)])
  }

  // MARK: Before the line is written

  func testSpendingBelowTheMinimumBalanceIsAskedAboutOnceAndNeverForbidden() async throws {
    let account = try await make(
      PaymentMethod(name: "Главный", isDefault: true), openings: [.rub: rub(55_000)])
    let stack = try XCTUnwrap(environment.stack)
    var draft = BankConditionsDraft()
    draft.minBalance = "50000"
    XCTAssertTrue(
      BankConditionsStore.write(
        try draft.conditions(accountId: account.id, cardId: nil, currency: .rub).get(), environment
      ))
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: moment, calendar: environment.calendar, rubPerUnit: [:],
      localeIdentifier: "en")
    let model = EntryDraftModel(
      references: try XCTUnwrap(environment.references),
      transactions: try XCTUnwrap(environment.transactions), calendar: .utc)
    model.reload()
    model.applyDefaults(today: today)
    model.draft.kind = .expense
    model.draft.paymentMethodId = account.id
    model.draft.currency = .rub
    model.draft.amount = rub(2_000)
    XCTAssertNil(
      model.minBalanceWarning(accounts: snapshot, bank: dataset.bankData), "stays above")
    model.draft.amount = rub(15_000)
    let warning = try XCTUnwrap(
      model.minBalanceWarning(accounts: snapshot, bank: dataset.bankData))
    XCTAssertEqual(warning.afterE4, rub(40_000))
    XCTAssertEqual(warning.minimumE4, rub(50_000))
    model.minBalanceAnswered = true
    XCTAssertNil(
      model.minBalanceWarning(accounts: snapshot, bank: dataset.bankData), "asked once")
    model.minBalanceAnswered = false
    model.draft.kind = .income
    XCTAssertNil(model.minBalanceWarning(accounts: snapshot, bank: dataset.bankData))
    model.draft.kind = .expense
    model.draft.currency = .usd
    XCTAssertNil(
      model.minBalanceWarning(accounts: snapshot, bank: dataset.bankData), "another currency")
    for choice in [AppLanguage.Choice.russian, .english] {
      let words = AppEnvironment()
      words.language.choice = choice
      let question = MinBalanceQuestion(warning: warning)
      let title = question.title(words)
      XCTAssertTrue(title.contains("40") && title.contains("50"), title)
      for key in ["entry.minBalance.record", "entry.minBalance.message"] {
        XCTAssertNotEqual(words.language(key, table: "Entry"), key, "\(choice) \(key)")
      }
    }
  }

  // MARK: Words

  func testEverySentenceAboutBanksIsInBothLanguages() {
    let note = BankNote.cardExpiry(
      accountId: UUID(), cardId: UUID(), expiresOn: MonthKey(year: 2026, month: 11),
      expired: false, attachedCount: 2)
    let line = BankLimitLine(
      accountId: UUID(), kind: .cash, currency: .rub, limitE4: rub(100_000), usedE4: rub(30_000),
      movements: [])
    let over = BankLimitLine(
      accountId: UUID(), kind: .sbp, currency: .rub, limitE4: rub(50_000), usedE4: rub(60_000),
      movements: [])
    let service = BankServiceProgress(
      accountId: UUID(), currency: .rub, spendTargetE4: rub(10_000), spentE4: rub(6_600),
      balanceTargetE4: rub(90_000), balanceE4: rub(80_000),
      through: DateOnly(year: 2026, month: 10, day: 31))
    let insurance = BankInsurance(
      bankId: UUID(), name: "Банк", accountIds: [], totalRub: rub(1_500_000),
      limitRub: rub(1_400_000), on: DateOnly(year: 2023, month: 3, day: 29))
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in BankText.keys {
        XCTAssertNotEqual(environment.language(key, table: BankText.table), key, "\(choice) \(key)")
      }
      for key in WorthALookNoteText.bankKeys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice) \(key)")
      }
      for action in [WorthALookNoteText.Action.openBank, .openForgotten, .rebind] {
        XCTAssertNotEqual(environment.language(action.key, table: "Overview"), action.key)
      }
      XCTAssertNotEqual(environment.language("why.look.bank", table: "Overview"), "why.look.bank")

      let used = BankText.limitLine(line, environment)
      XCTAssertTrue(used.contains("30") && used.contains("100") && used.contains("70"), used)
      let beyond = BankText.limitLine(over, environment)
      XCTAssertTrue(beyond.contains("10"), beyond)
      let spend = BankText.serviceLines(service, environment)
      XCTAssertEqual(spend.count, 2, "the spending and the balance, the two ways")
      XCTAssertTrue(spend[0].contains("3") && spend[0].contains("31"), spend[0])
      XCTAssertTrue(spend[1].contains("10"), spend[1])
      let free = BankText.serviceLines(
        BankServiceProgress(
          accountId: UUID(), currency: .rub, spendTargetE4: rub(10), spentE4: rub(10),
          balanceTargetE4: nil, balanceE4: nil, through: service.through), environment)
      XCTAssertEqual(free, [environment.language("bank.service.free", table: BankText.table)])
      let below = BankText.minBalanceLine(
        balanceE4: rub(40_000), minimumE4: rub(50_000), currency: .rub, environment)
      XCTAssertTrue(below.contains("10"), below)
      let lines = BankText.insuranceLines(insurance, environment)
      XCTAssertEqual(lines.count, 3)
      XCTAssertTrue(lines[1].contains("100"), lines[1])
      XCTAssertTrue(lines[2].contains("2023"), lines[2])
      XCTAssertTrue(BankText.idle(136, environment).contains("136"))
      XCTAssertTrue(
        BankText.expiry(MonthKey(year: 2028, month: 5), environment).contains("2028"))
      XCTAssertEqual(
        BankText.expiry(nil, environment),
        environment.language("bank.card.expiresNone", table: BankText.table))

      let said = WorthALookNoteText.text(
        .bank(note), debts: [:], accounts: [:], environment)
      XCTAssertTrue(said.contains("2"), said)
      let id = UUID()
      let notes: [BankNote] = [
        .limitNear(accountId: id, kind: .cash, leftE4: rub(15_000), currency: .rub),
        .limitExceeded(accountId: id, kind: .sbp, overE4: rub(10_000), currency: .rub),
        .minBalanceBelow(
          accountId: id, balanceE4: rub(40_000), minimumE4: rub(50_000), currency: .rub),
        .forgotten(count: 3, balanceRub: rub(80_000), month: MonthKey(year: 2026, month: 10)),
        .insuranceOver(
          bankId: id, name: "Банк", totalRub: rub(1_500_000), limitRub: rub(1_400_000)),
      ]
      for note in notes {
        let text = WorthALookNoteText.text(
          .bank(note), debts: [:], accounts: [id: "Тест"], environment)
        XCTAssertFalse(text.isEmpty, "\(choice) \(note)")
        XCTAssertFalse(text.contains("%"), "no format left over: \(text)")
      }
    }
  }

  func testEveryLineAboutBanksHasASymbolAnActionAndAnAlarmOnlyWhenItCannotWait() {
    let id = UUID()
    let cases: [(BankNote, alarm: Bool, done: Bool)] = [
      (.limitNear(accountId: id, kind: .cash, leftE4: rub(1), currency: .rub), false, false),
      (.limitExceeded(accountId: id, kind: .cash, overE4: rub(1), currency: .rub), true, false),
      (
        .minBalanceBelow(accountId: id, balanceE4: rub(1), minimumE4: rub(2), currency: .rub), true,
        false
      ),
      (
        .cardExpiry(
          accountId: id, cardId: id, expiresOn: MonthKey(year: 2026, month: 10), expired: true,
          attachedCount: 0), false, true
      ),
      (
        .forgotten(count: 1, balanceRub: rub(1), month: MonthKey(year: 2026, month: 10)), false,
        true
      ),
      (.insuranceOver(bankId: id, name: "Банк", totalRub: rub(2), limitRub: rub(1)), false, true),
    ]
    for (note, alarm, done) in cases {
      let line = WorthALookNote.bank(note)
      XCTAssertFalse(WorthALookNoteText.symbol(line).isEmpty)
      XCTAssertEqual(WorthALookNoteText.isAlarm(line), alarm, "\(note)")
      let actions = WorthALookNoteText.actions(line)
      XCTAssertFalse(actions.isEmpty)
      XCTAssertEqual(actions.contains(.done), done, "\(note) puts away only what may go")
      XCTAssertEqual(note.canBePutAway, done)
      XCTAssertTrue(line.id.hasPrefix("bank:"))
    }
    let withAttached = WorthALookNote.bank(
      .cardExpiry(
        accountId: id, cardId: id, expiresOn: MonthKey(year: 2026, month: 10), expired: false,
        attachedCount: 3))
    XCTAssertEqual(WorthALookNoteText.actions(withAttached).first, .rebind)
  }

  func testTheForgottenDaysSettingKeepsTheNumberAndForgetsTheDefault() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    var settings = BankSettings.standard
    settings.forgottenDays = 60
    let key = BankSettings.forgottenDaysKey
    var values: [String: String?] = [:]
    values.updateValue(settings.storedValues[key] ?? nil, forKey: key)
    XCTAssertEqual(accounts.apply(PlanningChange(settings: values, at: moment)), .done)
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(dataset.bankData.settings.forgottenDays, 60)
    XCTAssertEqual(ForgottenDaysSetting.choices, ForgottenDaysSetting.choices.sorted())
  }
}
