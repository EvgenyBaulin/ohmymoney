import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

private func money(_ text: String) -> AmountE4 {
  (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
}

private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

private func id(_ number: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

private func percent(_ text: String) -> CashbackPercent {
  CashbackPercent(decimal: Decimal(string: text)!)!
}

@Suite("«Я в поездке»: the trips to choose from and a new trip")
struct TripStartTests {
  private func event(
    _ number: Int, _ name: String, _ from: String, _ to: String, kind: EventKind = .trip,
    archived: Bool = false
  ) -> Event {
    Event(
      id: id(number), name: name, kind: kind, startDate: day(from), endDate: day(to),
      archived: archived)
  }

  @Test func onlyLiveTripsThatAreNotOverAreOfferedTheSoonestFirst() {
    let events = [
      event(1, "Турция", "2026-11-05", "2026-11-15"),
      event(2, "Бали", "2026-10-20", "2026-10-30"),
      event(3, "Прошлая", "2026-09-01", "2026-09-10"),
      event(4, "День рождения", "2026-10-25", "2026-10-25", kind: .birthday),
      event(5, "В архиве", "2026-12-01", "2026-12-10", archived: true),
      event(6, "Идёт сегодня", "2026-10-18", "2026-10-20"),
    ]
    let names = TripStart.choices(events: events, today: day("2026-10-20")).map(\.name)
    #expect(names == ["Идёт сегодня", "Бали", "Турция"])
  }

  @Test func aNewTripBecomesAnEventOfKindTripWithItsCurrenciesAndBudget() throws {
    let draft = TripStart.Draft(
      name: "  Турция ", startDate: day("2026-11-05"), endDate: day("2026-11-15"),
      tripCurrency: CurrencyCode("TRY"), budget: money("100000"), budgetCurrency: .rub)
    let event = try #require(TripStart.event(from: draft, today: day("2026-10-20")))
    #expect(event.kind == .trip)
    #expect(event.name == "Турция")
    #expect(event.tripCurrency == CurrencyCode("TRY"))
    #expect(event.budgetE4 == money("100000"))
    #expect(event.budgetCurrency == .rub)
    #expect(event.startDate == day("2026-11-05") && event.endDate == day("2026-11-15"))
  }

  @Test func noBudgetMeansNoBudgetCurrencyEither() throws {
    let draft = TripStart.Draft(
      name: "Бали", startDate: day("2026-10-20"), endDate: day("2026-10-21"), budget: .zero)
    let event = try #require(TripStart.event(from: draft, today: day("2026-10-20")))
    #expect(event.budgetE4 == nil)
    #expect(event.budgetCurrency == nil)
  }

  @Test func whatCannotBeStartedSaysWhy() {
    let today = day("2026-10-20")
    func issue(
      _ name: String, _ from: String, _ to: String, budget: AmountE4? = nil
    )
      -> TripStart.Issue?
    {
      TripStart.issue(
        of: TripStart.Draft(
          name: name, startDate: day(from), endDate: day(to), budget: budget), today: today)
    }
    #expect(issue("  ", "2026-10-20", "2026-10-21") == .emptyName)
    #expect(issue("Бали", "2026-10-22", "2026-10-21") == .endsBeforeItStarts)
    #expect(issue("Бали", "2026-10-01", "2026-10-19") == .alreadyOver)
    #expect(issue("Бали", "2026-10-20", "2026-10-21", budget: AmountE4(raw: -1)) == .negativeBudget)
    #expect(issue("Бали", "2026-10-01", "2026-10-20") == nil, "the last day is still a day of it")
    #expect(
      TripStart.event(
        from: TripStart.Draft(name: "", startDate: today, endDate: today), today: today) == nil)
  }

  @Test func theModeGoesOnForTheNewTripAndOffForGood() throws {
    let draft = TripStart.Draft(
      name: "Бали", startDate: day("2026-10-20"), endDate: day("2026-10-25"))
    let event = try #require(TripStart.event(from: draft, today: day("2026-10-20")))
    let on = TripMode.switchingOn(event, settings: .off)
    #expect(TripMode.state(settings: on, events: [event], today: day("2026-10-20")) == .on(event))
    #expect(TripMode.switchingOff(settings: on).activeEventId == nil)
  }
}

@Suite("The fee of an ATM withdrawal abroad laid into a transfer")
struct AtmFeeForTransferTests {
  private let account = PaymentMethod(id: id(1), name: "Т-Банк", currency: .rub)

  private func card(
    _ number: Int, percent text: String? = "1", fixed: Money? = nil, archived: Bool = false
  ) -> PaymentCard {
    PaymentCard(
      id: id(number), accountId: id(1), name: "Карта \(number)", archived: archived,
      foreign: CardForeignTerms(atmFeePercent: text.map(percent), atmFeeFixed: fixed))
  }

  @Test func theOnlyCardWithTermsGivesThePercentAndTheFixedPart() {
    let cards = [
      card(10, fixed: Money(amount: money("3"), currency: .usd)), card(11, percent: nil),
    ]
    let convert = TravelFees.converter { $0 == .usd ? 90 : nil }
    // 1 % of 10 000 and 3 $ at 90 ₽ = 270 ₽.
    let fee = TravelFees.atmFee(
      forWithdrawing: Money(amount: money("10000"), currency: .rub), from: account, cards: cards,
      convert: convert)
    #expect(fee == money("370"))
  }

  @Test func theMainCardWinsAndSeveralCardsWithoutAMainOneGiveNothing() {
    let first = card(10, percent: "1")
    let second = card(11, percent: "2")
    let withdrawal = Money(amount: money("1000"), currency: .rub)
    #expect(
      TravelFees.atmFee(forWithdrawing: withdrawal, from: account, cards: [first, second]) == nil)
    var main = account
    main.mainCardId = second.id
    #expect(
      TravelFees.atmFee(forWithdrawing: withdrawal, from: main, cards: [first, second])
        == money("20"))
  }

  @Test func archivedCardsOtherAccountsAndEmptyTermsGiveNothing() {
    let withdrawal = Money(amount: money("1000"), currency: .rub)
    #expect(
      TravelFees.atmFee(
        forWithdrawing: withdrawal, from: account, cards: [card(10, archived: true)]) == nil)
    #expect(
      TravelFees.atmFee(forWithdrawing: withdrawal, from: account, cards: [card(10, percent: nil)])
        == nil)
    var other = card(10)
    other.accountId = id(2)
    #expect(TravelFees.atmFee(forWithdrawing: withdrawal, from: account, cards: [other]) == nil)
    #expect(
      TravelFees.atmFee(
        forWithdrawing: Money(amount: .zero, currency: .rub), from: account, cards: [card(10)])
        == nil)
  }

  @Test func aFixedPartThatCannotBeConvertedLaysNothingRatherThanHalfOfTheFee() {
    let cards = [card(10, fixed: Money(amount: money("3"), currency: .usd))]
    let withdrawal = Money(amount: money("10000"), currency: .rub)
    #expect(
      TravelFees.atmFee(forWithdrawing: withdrawal, from: account, cards: cards) == nil)
    let noRate = TravelFees.converter { _ in nil }
    #expect(
      TravelFees.atmFee(
        forWithdrawing: withdrawal, from: account, cards: cards, convert: noRate) == nil)
  }

  @Test func theConverterGoesThroughRublesAndKeepsTheSameCurrency() {
    let convert = TravelFees.converter { code in
      ["USD": Decimal(90), "TRY": Decimal(3)][code.code]
    }
    let three = Money(amount: money("3"), currency: .usd)
    #expect(convert(three, .usd) == money("3"))
    #expect(convert(three, .rub) == money("270"))
    #expect(convert(three, CurrencyCode("TRY")) == money("90"))
    #expect(convert(Money(amount: money("30"), currency: CurrencyCode("TRY")), .rub) == money("90"))
    #expect(convert(Money(amount: money("1"), currency: CurrencyCode("XXX")), .rub) == nil)
  }
}

@Suite("Spending cash abroad is priced at the average rate it was bought at")
struct CashRateForAccountTests {
  private func transfer(_ rubles: String, _ foreign: String, to account: UUID) -> Transfer {
    Transfer(
      occurredAt: Date(), fromAccountId: id(1), fromCurrency: .rub, fromAmountE4: money(rubles),
      toAccountId: account, toCurrency: .usd, toAmountE4: money(foreign))
  }

  @Test func aCashAccountWithPurchasesGivesTheAverageRate() {
    let cash = PaymentMethod(id: id(7), name: "Наличные", kind: .cash, currency: .usd)
    let transfers = [
      transfer("98000", "1000", to: id(7)), transfer("50000", "500", to: id(7)),
      transfer("1", "1", to: id(8)),
    ]
    #expect(
      CashRate.rate(spendingFrom: cash, in: .usd, transfers: transfers)
        == Decimal(148_000) / Decimal(1_500))
  }

  @Test func aCardRublesAndAnAccountWithNoPurchaseGiveNoRate() {
    let transfers = [transfer("98000", "1000", to: id(7))]
    let card = PaymentMethod(id: id(7), name: "Карта", kind: .card, currency: .usd)
    let cash = PaymentMethod(id: id(7), name: "Наличные", kind: .cash, currency: .usd)
    let empty = PaymentMethod(id: id(9), name: "Пусто", kind: .cash, currency: .usd)
    #expect(CashRate.rate(spendingFrom: card, in: .usd, transfers: transfers) == nil)
    #expect(CashRate.rate(spendingFrom: cash, in: .rub, transfers: transfers) == nil)
    #expect(CashRate.rate(spendingFrom: empty, in: .usd, transfers: transfers) == nil)
    #expect(CashRate.rate(spendingFrom: cash, in: .eur, transfers: transfers) == nil)
  }
}

@Suite("A gathered goal starts a trip")
struct TripGoalDraftTests {
  @Test func aGatheredGoalGivesATripNamedLikeItWithItsMoneyAsTheBudget() throws {
    let draft = try #require(
      TripGoal.draft(
        goalName: "Отпуск", target: money("100000"), saved: money("120000"), currency: .eur,
        targetDate: day("2026-12-20"), today: day("2026-10-20")))
    #expect(draft.name == "Отпуск")
    #expect(draft.budget == money("120000"))
    #expect(draft.budgetCurrency == .eur)
    #expect(draft.startDate == day("2026-12-20"))
    #expect(draft.endDate == day("2027-01-02"), "fourteen days, the first included")
    #expect(TripStart.event(from: draft, today: day("2026-10-20"))?.kind == .trip)
  }

  @Test func aGoalNotGatheredYetGivesNoTrip() {
    #expect(
      TripGoal.draft(
        goalName: "Отпуск", target: money("100000"), saved: money("99999"), currency: .rub,
        targetDate: nil, today: day("2026-10-20")) == nil)
    #expect(
      TripGoal.draft(
        goalName: "Без цели", target: .zero, saved: money("5"), currency: .rub, targetDate: nil,
        today: day("2026-10-20")) == nil)
  }

  @Test func aDateInThePastStartsTheTripToday() throws {
    let draft = try #require(
      TripGoal.draft(
        goalName: "Отпуск", target: money("10"), saved: money("10"), currency: .rub,
        targetDate: day("2026-09-01"), today: day("2026-10-20"), days: 3))
    #expect(draft.startDate == day("2026-10-20") && draft.endDate == day("2026-10-22"))
    #expect(TripStart.issue(of: draft, today: day("2026-10-20")) == nil)
  }
}
