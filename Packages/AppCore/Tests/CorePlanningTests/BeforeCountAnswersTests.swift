import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The answers «Больше не спрашивать для этой сверки» keeps hold only while their
/// reconciliation is a count of the latest counted day of some balance: a count of every
/// balance it counted on a later day lets the answer go.
@Suite("Answers remembered for a reconciliation")
struct BeforeCountAnswersTests {
  typealias Fx = CashFx

  /// Main counted on the 10th and again on the 15th, Card only on the 10th: the sheet of the
  /// 10th is still Card's latest count and keeps its answer; the sheet of the 12th, whose only
  /// balance was counted again on a later day, loses its; an id that is no reconciliation at
  /// all goes too.
  @Test func prunedKeepsOnlyLatestCounts() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000"), (Fx.card, .rub, "500")], at: Fx.at("2026-09-10", 9))
    let both = fx.reconciliations[0].id
    fx.count([(Fx.main, .rub, "900")], at: Fx.at("2026-09-12", 9))
    let middle = fx.reconciliations[1].id
    fx.count([(Fx.main, .rub, "800")], at: Fx.at("2026-09-15", 9))
    let latest = fx.reconciliations[2].id
    let stranger = Fx.id(999)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now)

    let answers: [UUID: Bool] = [both: true, middle: false, latest: false, stranger: true]
    #expect(
      BeforeCountAnswers.pruned(answers, balances: balances) == [both: true, latest: false])
    #expect(BeforeCountAnswers.pruned([:], balances: balances).isEmpty)
    #expect(BeforeCountAnswers.pruned(answers, balances: .empty).isEmpty)
  }

  /// An operation is asked about every count of its day in turn, so an answer given for the
  /// morning count of a day that has an evening count too is still of use, and stays: the
  /// setup at 09:00 and the sheet at 21:30 both keep theirs. A count of the next day lets both
  /// go. The day is the owner's: 21:30 UTC is already the next day in Moscow.
  @Test func aCountOfTheLatestDayKeepsItsAnswer() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-15", 9), kind: .opening)
    let morning = fx.reconciliations[0].id
    fx.count([(Fx.main, .rub, "700")], at: Fx.at("2026-09-15", 21, 30))
    let evening = fx.reconciliations[1].id
    let answers: [UUID: Bool] = [morning: true, evening: false]
    #expect(
      BeforeCountAnswers.pruned(
        answers, balances: ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now))
        == answers)
    #expect(
      BeforeCountAnswers.pruned(
        answers, balances: Self.balances(fx, calendar: .moscow)) == [evening: false],
      "21:30 UTC is already the 16th in Moscow")

    fx.count([(Fx.main, .rub, "650")], at: Fx.at("2026-09-16", 10))
    let next = fx.reconciliations[2].id
    #expect(
      BeforeCountAnswers.pruned(
        [morning: true, evening: false, next: true],
        balances: ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now))
        == [next: true])
  }

  private static func balances(_ fx: Fx, calendar: CalendarContext) -> AccountBalances {
    let dataset = fx.ledger.dataset
    return AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: Fx.now, calendar: calendar)
  }

  /// «Больше не спрашивать для этой сверки» is offered only where the answer would be kept. The
  /// card counted alone on the 10th and on the 20th: an operation dated the 10th is asked about
  /// the count of the 10th without the offer, one dated the 20th with it. A day holding a count
  /// of the card, counted again later, and one of the main account, never counted again,
  /// offers it on the walk only for the main account's count.
  @Test func onlyAnAnswerThatWouldBeKeptIsOffered() throws {
    var fx = Fx()
    let card = BalanceKey(accountId: Fx.card, currency: .rub)
    let main = BalanceKey(accountId: Fx.main, currency: .rub)
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-10", 9))
    let early = fx.reconciliations[0].id
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-10", 15))
    let ofMain = fx.reconciliations[1].id
    fx.count([(Fx.card, .rub, "400")], at: Fx.at("2026-09-20", 9))
    let latest = fx.reconciliations[2].id
    let saved = Fx.at("2026-09-25", 12)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: saved)

    #expect(!BeforeCountAnswers.keeps(early, balances: balances))
    #expect(BeforeCountAnswers.keeps(ofMain, balances: balances))
    #expect(BeforeCountAnswers.keeps(latest, balances: balances))
    #expect(!BeforeCountAnswers.keeps(Fx.id(999), balances: balances))

    func questions(on day: String, _ keys: [BalanceKey]) -> CountQuestions? {
      guard
        case .ask(let questions) = AccountReconciliation.countToAsk(
          occurredAt: Fx.at(day, 20), savedAt: saved, keys: keys, balances: balances,
          calendar: .utc, remembered: [:])
      else { return nil }
      return questions
    }
    let old = try #require(questions(on: "2026-09-10", [card]))
    #expect(old.reconciliation == early)
    #expect(!old.remembers)
    let current = try #require(questions(on: "2026-09-20", [card]))
    #expect(current.reconciliation == latest)
    #expect(current.remembers)

    let both = try #require(questions(on: "2026-09-10", [card, main]))
    #expect(both.reconciliation == early)
    #expect(!both.remembers)
    guard case .ask(let next) = both.answer(wasBefore: false) else {
      Issue.record("«Нет» asks about the count of the main account")
      return
    }
    #expect(next.reconciliation == ofMain)
    #expect(next.remembers)

    // A walk made without the counts' balances offers it wherever the reconciliation is known.
    let bare = CountQuestions(
      counts: [Fx.at("2026-09-10", 9)], reconciliations: [early], occurredAt: saved,
      calendar: .utc)
    #expect(bare.remembers)
    #expect(
      !CountQuestions(counts: [Fx.at("2026-09-10", 9)], occurredAt: saved, calendar: .utc)
        .remembers)
  }

  /// Main and Card counted in one sheet on the 10th, «до» remembered for it; Main alone counted
  /// again on the 20th. The answer is still kept — the sheet is Card's latest count — but it
  /// answers only for Card: a Main operation of the 10th, typed on the 21st, is asked about the
  /// sheet again without the offer to remember, and so is a transfer between the two. A Card
  /// operation of that day is still dated by the answer.
  @Test func anAnswerIsNotUsedForAnAccountCountedAgainAlone() throws {
    var fx = Fx()
    let main = BalanceKey(accountId: Fx.main, currency: .rub)
    let card = BalanceKey(accountId: Fx.card, currency: .rub)
    let sheet = Fx.at("2026-09-10", 11)
    fx.count([(Fx.main, .rub, "1000"), (Fx.card, .rub, "500")], at: sheet)
    let both = fx.reconciliations[0].id
    fx.count([(Fx.main, .rub, "900")], at: Fx.at("2026-09-20", 9))
    let saved = Fx.at("2026-09-21", 12)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: saved)
    let remembered = BeforeCountAnswers.pruned([both: true], balances: balances)
    #expect(remembered == [both: true], "the sheet is still Card's latest count")

    func ask(_ keys: [BalanceKey]) -> CountAsk {
      AccountReconciliation.countToAsk(
        occurredAt: Fx.at("2026-09-10", 20), savedAt: saved, keys: keys, balances: balances,
        calendar: .utc, remembered: remembered)
    }
    guard case .ask(let ofMain) = ask([main]) else {
      Issue.record("a Main operation of the 10th is asked about the sheet again")
      return
    }
    #expect(ofMain.reconciliation == both)
    #expect(!ofMain.remembers)
    guard case .ask(let ofTransfer) = ask([main, card]) else {
      Issue.record("a transfer that moves Main is asked about the sheet again")
      return
    }
    #expect(ofTransfer.reconciliation == both)
    #expect(!ofTransfer.remembers)
    guard case .answered(let stamp) = ask([card]) else {
      Issue.record("a Card operation of the 10th is still dated by the answer")
      return
    }
    #expect(stamp == sheet.addingTimeInterval(-1))
  }

  /// A count of one total from before the accounts anchors nothing, so it is never the latest
  /// count of a balance.
  @Test func aTotalKeepsNoAnswer() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-10", 9), kind: .total)
    let total = fx.reconciliations[0].id
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now)
    #expect(BeforeCountAnswers.pruned([total: true], balances: balances).isEmpty)
  }
}
