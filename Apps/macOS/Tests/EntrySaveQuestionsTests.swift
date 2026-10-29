import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The questions asked before a new operation is written (`EntrySaveQuestions`): the line at the
/// bottom and the form at the side save through the same code, so one set of drafts gives one
/// list of questions in both. The scenarios run on the fixed clock of `AccountsScenarioDatabaseCase`
/// (noon, 16 September 2026, UTC calendar), so no time zone of the Mac matters.
@MainActor
final class EntrySaveQuestionsTests: AccountsScenarioDatabaseCase {
  private let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25))

  private func model(
    on account: PaymentMethod, amount: Int64, currency: CurrencyCode = .rub,
    editing: Bool = false
  ) throws -> EntryDraftModel {
    let model = EntryDraftModel(
      references: try XCTUnwrap(environment.references),
      transactions: try XCTUnwrap(environment.transactions), calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    model.applyDefaults(today: today)
    model.draft.kind = .expense
    model.draft.paymentMethodId = account.id
    model.draft.currency = currency
    model.draft.amount = rub(amount)
    model.draft.occurredAt = noon
    return model
  }

  /// Every question the draft has to answer, one after the other, each answered «Записать всё
  /// равно» (the way both save paths go on after it).
  private func asked(
    _ model: EntryDraftModel, _ money: EntrySaveQuestions.Money
  ) -> [EntrySaveQuestions.Kind] {
    var kinds: [EntrySaveQuestions.Kind] = []
    while let question = EntrySaveQuestions.next(
      for: model, environment: environment, money: money, now: Date()), kinds.count < 8
    {
      kinds.append(question.kind)
      switch question.kind {
      case .ahead: model.aheadAnswered = true
      case .overLimit: model.overLimitAnswered = true
      case .minBalance: model.minBalanceAnswered = true
      case .repeated: model.repeatConfirmed = true
      }
    }
    return kinds
  }

  /// A card with `available` left of its limit, an opening balance and a balance to keep.
  private func card(
    opening: Int64, minimum: Int64?, available: Int64
  ) async throws -> (
    PaymentMethod, EntrySaveQuestions.Money
  ) {
    let account = try await make(
      PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub, credit: terms),
      openings: [.rub: rub(opening)])
    if let minimum {
      var draft = BankConditionsDraft()
      draft.minBalance = "\(minimum)"
      XCTAssertTrue(
        BankConditionsStore.write(
          try draft.conditions(accountId: account.id, cardId: nil, currency: .rub).get(),
          environment))
    }
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: moment, calendar: environment.calendar, rubPerUnit: [:],
      localeIdentifier: "en")
    let now = CreditCardNow(
      availableE4: rub(available), limitE4: rub(150_000), debtE4: rub(150_000 - available))
    return (
      account,
      EntrySaveQuestions.Money(cards: [account.id: now], balances: (snapshot, dataset.bankData))
    )
  }

  func testSpendingPastTheLimitAsksAboutTheLimitOnly() async throws {
    let (account, money) = try await card(opening: 400_000, minimum: nil, available: 5_000)
    XCTAssertEqual(asked(try model(on: account, amount: 7_500), money), [.overLimit])
  }

  func testSpendingBelowTheKeptBalanceAsksAboutTheBalanceOnly() async throws {
    let (account, money) = try await card(opening: 55_000, minimum: 50_000, available: 100_000)
    XCTAssertEqual(asked(try model(on: account, amount: 15_000), money), [.minBalance])
  }

  func testBothQuestionsAreAskedLimitFirst() async throws {
    let (account, money) = try await card(opening: 55_000, minimum: 50_000, available: 5_000)
    XCTAssertEqual(asked(try model(on: account, amount: 15_000), money), [.overLimit, .minBalance])
  }

  func testNothingToAskWithinTheLimitAndTheBalance() async throws {
    let (account, money) = try await card(opening: 400_000, minimum: 50_000, available: 100_000)
    XCTAssertEqual(asked(try model(on: account, amount: 1_000), money), [])
  }

  func testASavedOperationTheEditorWasNotToldAboutAsksNothing() async throws {
    let (account, money) = try await card(opening: 55_000, minimum: 50_000, available: 5_000)
    let edited = try model(on: account, amount: 15_000, editing: true)
    edited.draft.occurredAt = noon.addingTimeInterval(30 * 86_400)
    XCTAssertEqual(asked(edited, money), [])
  }

  func testSpendingInAnotherCurrencyThanTheCardsAsksNothing() async throws {
    let (account, money) = try await card(opening: 55_000, minimum: 50_000, available: 5_000)
    XCTAssertEqual(asked(try model(on: account, amount: 15_000, currency: .usd), money), [])
  }

  func testADateAfterTodayIsAskedFirstThenTheCard() async throws {
    let (account, money) = try await card(opening: 55_000, minimum: 50_000, available: 5_000)
    let ahead = try model(on: account, amount: 15_000)
    ahead.draft.occurredAt = noon.addingTimeInterval(3 * 86_400)
    XCTAssertEqual(asked(ahead, money), [.ahead, .overLimit, .minBalance])
  }

  func testARepeatOfTheLastMinutesIsAskedAfterTheCardQuestions() async throws {
    let (account, money) = try await card(opening: 400_000, minimum: nil, available: 5_000)
    try spend(7_500, on: account.id, at: noon)
    let again = try model(on: account, amount: 7_500)
    XCTAssertEqual(asked(again, money), [.overLimit, .repeated])
  }

  // MARK: The line and the form, in windows

  /// The same repeat is asked in the line at the bottom and in the form at the side: a sheet
  /// comes up over the window and nothing is written.
  func testTheLineAndTheFormAskAboutARepeatAlike() async throws {
    for style in [EntryStyle.line, .form] {
      let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
      let host = try await EntryHost(opensDetails: false, style: style) { environment in
        try environment.references!.save(cafe)
        var draft = TransactionDraft(
          kind: .expense, occurredAt: Date(), amount: AmountE4(whole: 300), note: "кофе")
        draft.normalizeSinglePart()
        draft.parts[0].categoryId = cafe.id
        _ = try environment.transactions!.save(try draft.materialize())
      }
      defer { host.close() }
      if style == .line {
        try host.type("кофе 300", into: try host.line())
        host.pressReturn()
      } else {
        let prompt = host.environment.language("entry.quick.prompt", table: "Entry")
        let quick = try host.field(prompt: prompt)
        try host.type("кофе 300", into: quick)
        host.pressReturn()
        host.pressReturn()
      }
      XCTAssertTrue(
        host.settle(until: { host.window.attachedSheet != nil }), "\(style): no question")
      XCTAssertEqual(try host.transactions.count(), 1, "\(style): nothing written yet")
    }
  }
}
