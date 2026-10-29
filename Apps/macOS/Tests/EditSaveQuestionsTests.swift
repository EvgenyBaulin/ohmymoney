import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// A saved operation being edited asks about a card's limit and the balance a bank asks to keep
/// only when the edit itself makes either worse than the operation was saved (`savedOperation`,
/// `EntrySaveQuestions`). Every scenario runs through the planner the line, the form, the sheet
/// and the inspector share, on the fixed clock of `AccountsScenarioDatabaseCase` (noon,
/// 16 September 2026, UTC calendar), so no time zone of the Mac matters.
@MainActor
final class EditSaveQuestionsTests: AccountsScenarioDatabaseCase {
  private let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25))

  /// A credit card, with a balance to keep when `minimum` is given.
  private func card(
    _ name: String, opening: Int64 = 400_000, minimum: Int64? = nil
  ) async throws -> PaymentMethod {
    let account = try await make(
      PaymentMethod(name: name, kind: .card, currency: .rub, credit: terms),
      openings: [.rub: rub(opening)])
    if let minimum {
      var draft = BankConditionsDraft()
      draft.minBalance = "\(minimum)"
      XCTAssertTrue(
        BankConditionsStore.write(
          try draft.conditions(accountId: account.id, cardId: nil, currency: .rub).get(),
          environment))
    }
    return account
  }

  /// The cards and balances as the screens would hand them over, `available` left of each
  /// card's limit now — the saved operation counted in it.
  private func money(_ available: [UUID: Int64]) async throws -> EntrySaveQuestions.Money {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: moment, calendar: environment.calendar, rubPerUnit: [:],
      localeIdentifier: "en")
    var cards: [UUID: CreditCardNow] = [:]
    for (id, left) in available {
      cards[id] = CreditCardNow(
        availableE4: rub(left), limitE4: rub(150_000), debtE4: rub(150_000 - left))
    }
    return EntrySaveQuestions.Money(cards: cards, balances: (snapshot, dataset.bankData))
  }

  /// An editor of a spending of `amount` just saved on `account`.
  private func editor(on account: PaymentMethod, amount: Int64) throws -> TransactionEditorModel {
    let entry = try spend(amount, on: account.id)
    return TransactionEditorModel(entry: entry, environment: environment)
  }

  private func asked(
    _ editor: TransactionEditorModel, _ money: EntrySaveQuestions.Money
  ) -> [EntrySaveQuestions.Kind] {
    var kinds: [EntrySaveQuestions.Kind] = []
    while let question = EntrySaveQuestions.next(
      for: editor.draft, environment: environment, money: money, now: Date()), kinds.count < 4
    {
      kinds.append(question.kind)
      switch question.kind {
      case .overLimit: editor.draft.overLimitAnswered = true
      case .minBalance: editor.draft.minBalanceAnswered = true
      case .ahead, .repeated, .pause, .mileage: return kinds
      }
    }
    return kinds
  }

  // MARK: The card's limit

  func testRaisingTheAmountPastTheLimitAsks() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: 5_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.amount = rub(20_000)
    XCTAssertEqual(asked(edit, money), [.overLimit])
  }

  func testRaisingTheAmountWithinTheLimitAsksNothing() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: 5_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.amount = rub(15_000)
    XCTAssertEqual(asked(edit, money), [], "up to what is left of the limit is fine")
  }

  func testLoweringTheAmountOrChangingTheNoteAsksNothing() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: -3_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.note = "dinner"
    XCTAssertEqual(asked(edit, money), [], "a card already over, a note changed")
    edit.draft.draft.amount = rub(2_000)
    XCTAssertEqual(asked(edit, money), [], "a smaller amount")
  }

  func testMakingACardThatIsAlreadyOverWorseAsks() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: -3_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.amount = rub(12_000)
    XCTAssertEqual(asked(edit, money), [.overLimit])
    let again = try editor(on: account, amount: 10_000)
    XCTAssertEqual(asked(again, money), [], "unchanged, nothing is asked")
  }

  func testMovingToACardThatGoesPastItsLimitAsks() async throws {
    let from = try await card("Т-Банк")
    let tight = try await card("Альфа")
    let roomy = try await card("Сбер")
    let money = try await money([from.id: 100_000, tight.id: 1_000, roomy.id: 100_000])
    let edit = try editor(on: from, amount: 10_000)
    edit.draft.draft.paymentMethodId = roomy.id
    XCTAssertEqual(asked(edit, money), [], "a card with room")
    edit.draft.draft.paymentMethodId = tight.id
    XCTAssertEqual(asked(edit, money), [.overLimit])
  }

  func testAnotherCurrencyOrADayAheadTakesNothingFromTheCard() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: 5_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.amount = rub(20_000)
    edit.draft.draft.occurredAt = Date().addingTimeInterval(30 * 86_400)
    XCTAssertEqual(asked(edit, money), [], "a day ahead is not in the balance yet")
    edit.draft.draft.occurredAt = noon.addingTimeInterval(-3_600)
    edit.draft.draft.currency = .usd
    XCTAssertEqual(asked(edit, money), [], "another currency than the card's")
  }

  // MARK: The balance to keep

  func testRaisingTheAmountBelowTheKeptBalanceAsks() async throws {
    let account = try await card("Т-Банк", opening: 55_000, minimum: 50_000)
    let money = try await money([account.id: 100_000])
    let edit = try editor(on: account, amount: 1_000)
    edit.draft.draft.amount = rub(3_000)
    XCTAssertEqual(asked(edit, money), [], "55 000 less 2 000 more stays above 50 000")
    edit.draft.draft.amount = rub(20_000)
    XCTAssertEqual(asked(edit, money), [.minBalance])
  }

  func testAnAccountAlreadyBelowTheKeptBalanceIsNotAskedAboutAgain() async throws {
    let account = try await card("Т-Банк", opening: 45_000, minimum: 50_000)
    let money = try await money([account.id: 100_000])
    let edit = try editor(on: account, amount: 1_000)
    edit.draft.draft.amount = rub(20_000)
    XCTAssertEqual(asked(edit, money), [])
  }

  // MARK: Saving

  func testSavingAnEditThatWorsensTheLimitWaitsForTheAnswer() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: 5_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.amount = rub(20_000)
    edit.draft.draft.normalizeSinglePart()
    XCTAssertFalse(edit.save(store: store, environment: environment, money: money))
    guard case .overLimit = edit.saveQuestion else {
      return XCTFail("the edit asked \(String(describing: edit.saveQuestion))")
    }
    XCTAssertEqual(try liveEntries().first?.transaction.amountE4, rub(10_000), "nothing written")

    edit.answerSaveQuestion()
    XCTAssertNil(edit.saveQuestion)
    XCTAssertTrue(edit.save(store: store, environment: environment, money: money))
    XCTAssertEqual(try liveEntries().first?.transaction.amountE4, rub(20_000))
  }

  func testSavingAnEditThatWorsensNothingAsksNothing() async throws {
    let account = try await card("Т-Банк")
    let money = try await money([account.id: 5_000])
    let edit = try editor(on: account, amount: 10_000)
    edit.draft.draft.note = "tea"
    XCTAssertTrue(edit.save(store: store, environment: environment, money: money))
    XCTAssertNil(edit.saveQuestion)
  }
}
