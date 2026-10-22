import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Synthetic subscriptions only. Dates are fixed around 14 October 2026.
enum SubFixtures {
  static let today = DateOnly(year: 2026, month: 10, day: 14)

  static func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  static func subscription(
    _ name: String, _ amount: Int64, freq: Frequency = .monthly, currency: CurrencyCode = .rub,
    next: DateOnly? = nil, end: DateOnly? = nil, trialEnd: DateOnly? = nil
  ) -> ScheduledPayment {
    ScheduledPayment(
      name: name, kind: .subscription, amountE4: rub(amount), currency: currency, freq: freq,
      day: (next ?? day(10, 20)).day, month: freq == .yearly ? (next ?? day(10, 20)).month : nil,
      nextDate: next ?? day(10, 20), endDate: end, trialEnd: trialEnd)
  }

  static func ledger(_ entries: [TransactionEntry] = [], book: PlanningBook) -> Ledger {
    Ledger(dataset: Dataset(entries: entries, planning: book), calendar: .utc)
  }

  /// A charge written the way «Отметить оплаченным» writes it.
  static func charge(
    of payment: ScheduledPayment, on charged: DateOnly, amount: Int64, due: DateOnly? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(charged), currency: payment.currency,
      amount: rub(amount))
    draft.parts = [PartDraft(amount: rub(amount))]
    var entry = try draft.materialize()
    entry.transaction.externalId =
      "sched:\(payment.id.uuidString.lowercased()):\((due ?? charged).iso)"
    return entry
  }

  static func lines(
    _ payments: [ScheduledPayment], subs: SubscriptionBook = .empty,
    rates: [CurrencyCode: Decimal] = [:]
  ) -> [SubscriptionLine] {
    SubscriptionCosts.lines(
      book: PlanningBook(scheduled: payments), subscriptions: subs, today: today,
      rubPerUnit: rates)
  }
}

@Suite("Subscription costs")
struct SubscriptionCostsTests {
  typealias F = SubFixtures

  @Test func costPerMonthYearAndDayInRubles() {
    let music = F.subscription("Music", 299)
    let cloud = F.subscription("Cloud", 2_400, freq: .yearly, next: F.day(12, 1))
    let lines = F.lines([music, cloud])
    #expect(lines.map(\.payment.name) == ["Music", "Cloud"])
    let byName = Dictionary(uniqueKeysWithValues: lines.map { ($0.payment.name, $0) })
    #expect(byName["Music"]?.yearlyRub == F.rub(3_588))
    #expect(byName["Cloud"]?.monthlyRub == F.rub(200))
    #expect(byName["Cloud"]?.yearlyRub == F.rub(2_400))
    let totals = SubscriptionCosts.totals(of: lines)
    #expect(totals.monthlyRub == F.rub(499))
    #expect(totals.yearlyRub == F.rub(5_988))
    #expect(SubscriptionCosts.perDay(yearlyRub: F.rub(3_650)) == F.rub(10))
  }

  @Test func foreignCurrencyNeedsARate() {
    let dollars = F.subscription("Service", 10, currency: .usd)
    let none = F.lines([dollars])
    #expect(none.first?.yearlyRub == nil)
    #expect(SubscriptionCosts.totals(of: none).withoutRate == [dollars.id])
    #expect(SubscriptionCosts.totals(of: none).yearlyRub == .zero)
    let rated = F.lines([dollars], rates: [.usd: 100])
    #expect(rated.first?.monthlyRub == F.rub(1_000))
    #expect(rated.first?.yearlyRub == F.rub(12_000))
  }

  @Test func onlyRunningSubscriptionsCount() {
    let bill = ScheduledPayment(
      name: "Rent", kind: .bill, amountE4: F.rub(30_000), day: 20, nextDate: F.day(10, 20))
    var stopped = F.subscription("Stopped", 100)
    stopped.active = false
    let ended = F.subscription("Ended", 100, end: F.day(10, 1))
    let cancelledLater = F.subscription("Until November", 100, end: F.day(11, 1))
    let oneOff = F.subscription("Once", 100, next: F.day(10, 20), end: F.day(10, 20))
    let names = F.lines([bill, stopped, ended, cancelledLater, oneOff]).map(\.payment.name)
    #expect(names == ["Until November"])
  }

  @Test func priceHistoryIsUsed() {
    let music = F.subscription("Music", 299)
    let book = PlanningBook(
      scheduled: [music],
      prices: [
        SubscriptionPrice(paymentId: music.id, date: F.day(9, 1), amountE4: F.rub(399))
      ])
    let lines = SubscriptionCosts.lines(
      book: book, subscriptions: .empty, today: F.today, rubPerUnit: [:])
    #expect(lines.first?.price == F.rub(399))
    #expect(lines.first?.yearlyRub == F.rub(4_788))
  }
}

@Suite("Year or month")
struct BillingComparisonTests {
  typealias F = SubFixtures

  @Test func yearlyPlanCheaperThanTwelveMonths() throws {
    let music = F.subscription("Music", 300)
    let terms = SubscriptionTerms(paymentId: music.id, yearlyPlanE4: F.rub(3_000))
    let result = try #require(
      BillingComparisons.compare(payment: music, terms: terms, price: F.rub(300)))
    #expect(result.twelveMonths == F.rub(3_600))
    #expect(result.saving == F.rub(600))
    #expect(result.savingPercent == 17)
    #expect(result.cheaper == .yearly)
    #expect(result.equivalentMonths == 10)
  }

  @Test func paymentThatIsYearlyComparesToMonthlyPlan() throws {
    let cloud = F.subscription("Cloud", 3_000, freq: .yearly, next: F.day(12, 1))
    let terms = SubscriptionTerms(paymentId: cloud.id, monthlyPlanE4: F.rub(200))
    let result = try #require(
      BillingComparisons.compare(payment: cloud, terms: terms, price: F.rub(3_000)))
    #expect(result.saving == F.rub(-600))
    #expect(result.cheaper == .monthly)
    #expect(result.savingPercent == -25)
  }

  @Test func withoutTheOtherPlanThereIsNothingToShow() {
    let music = F.subscription("Music", 300)
    #expect(BillingComparisons.compare(payment: music, terms: nil, price: F.rub(300)) == nil)
    let terms = SubscriptionTerms(paymentId: music.id)
    #expect(BillingComparisons.compare(payment: music, terms: terms, price: F.rub(300)) == nil)
    var weekly = music
    weekly.freq = .weekly
    let both = SubscriptionTerms(paymentId: music.id, yearlyPlanE4: F.rub(1))
    #expect(BillingComparisons.compare(payment: weekly, terms: both, price: F.rub(300)) == nil)
  }
}

@Suite("Family subscriptions")
struct FamilyShareTests {
  typealias F = SubFixtures

  @Test func equalSharesAddUpToTheAmount() {
    let people = [UUID(), UUID(), UUID()]
    let share = FamilyShares.split(AmountE4(raw: 1_000_001), people: people)
    #expect(share.mine + AmountE4.sum(share.others.map(\.amount)) == share.total)
    #expect(share.others.count == 3)
    // The extra unit goes to the first share, which is the owner's.
    #expect(share.mine == AmountE4(raw: 250_001))
    #expect(share.others.allSatisfy { $0.amount == AmountE4(raw: 250_000) })
  }

  @Test func ownerWhoDoesNotUseItPaysNothingOfIt() {
    let people = [UUID(), UUID()]
    let share = FamilyShares.split(F.rub(399), people: people, ownerUses: false)
    #expect(share.mine == .zero)
    #expect(AmountE4.sum(share.others.map(\.amount)) == F.rub(399))
  }

  @Test func nobodyChosenMeansTheOwnerPaysAll() {
    let share = FamilyShares.split(F.rub(399), people: [])
    #expect(share.mine == F.rub(399))
    #expect(share.others.isEmpty)
  }

  @Test func aPersonListedTwiceIsCountedOnce() {
    let person = UUID()
    let share = FamilyShares.split(F.rub(100), people: [person, person])
    #expect(share.others.count == 1)
    #expect(share.mine == F.rub(50))
  }

  @Test func bookReadsPeopleOnceInOrder() {
    let payment = UUID()
    let first = UUID()
    let second = UUID()
    let book = SubscriptionBook(
      users: [
        SubscriptionUser(paymentId: payment, personId: first),
        SubscriptionUser(paymentId: UUID(), personId: UUID()),
        SubscriptionUser(paymentId: payment, personId: second),
        SubscriptionUser(paymentId: payment, personId: first),
      ])
    #expect(book.people(of: payment) == [first, second])
  }
}

@Suite("Use of a subscription")
struct SubscriptionUsageTests {
  typealias F = SubFixtures

  @Test func costPerUseNeedsMarks() {
    let id = UUID()
    let none = SubscriptionUsage.value(
      paymentId: id, monthlyRub: F.rub(300), marks: [], today: F.today)
    #expect(none.hasMarks == false)
    #expect(none.perUseRub == nil)
    #expect(none.lastUsed == nil)
  }

  @Test func costPerUseOverTheLastThirtyDays() {
    let id = UUID()
    let marks = [F.day(10, 14), F.day(10, 10), F.day(10, 10), F.day(9, 20), F.day(9, 1)]
      .map { UsageMark(paymentId: id, day: $0) }
    let value = SubscriptionUsage.value(
      paymentId: id, monthlyRub: F.rub(300), marks: marks, today: F.today)
    // 15 Sep…14 Oct holds 14 Oct, 10 Oct (twice, one day) and 20 Sep: three days.
    #expect(value.usedDays == 3)
    #expect(value.perUseRub == F.rub(100))
    #expect(value.lastUsed == F.day(10, 14))
  }

  @Test func marksOfOtherSubscriptionsAndOldOnesDoNotCount() {
    let id = UUID()
    let marks = [
      UsageMark(paymentId: id, day: F.day(7, 1)),
      UsageMark(paymentId: UUID(), day: F.today),
    ]
    let value = SubscriptionUsage.value(
      paymentId: id, monthlyRub: F.rub(300), marks: marks, today: F.today)
    #expect(value.usedDays == 0)
    #expect(value.perUseRub == nil)
    #expect(value.hasMarks)
    #expect(value.lastUsed == F.day(7, 1))
  }
}

@Suite("Service catalogue")
struct ServiceCatalogTests {
  @Test func knownServicesByNameInBothLanguages() {
    #expect(ServiceCatalog.type(of: "Яндекс Музыка") == .music)
    #expect(ServiceCatalog.type(of: "Spotify Premium") == .music)
    #expect(ServiceCatalog.type(of: "Кинопоиск") == .video)
    #expect(ServiceCatalog.type(of: "iCloud+ 200 GB") == .cloud)
    #expect(ServiceCatalog.type(of: "ChatGPT Plus") == .assistant)
    #expect(ServiceCatalog.type(of: "Claude Pro") == .assistant)
    #expect(ServiceCatalog.type(of: "Литрес") == .books)
    #expect(ServiceCatalog.type(of: "Gym") == nil)
  }

  @Test func shortFragmentsMatchWholeWordsOnly() {
    #expect(ServiceCatalog.type(of: "Ivi") == .video)
    #expect(ServiceCatalog.type(of: "Привилегия клуба") == nil)
    #expect(ServiceCatalog.type(of: "Restart course") == nil)
  }

  @Test func ownersTypeBeatsTheCatalogue() {
    #expect(ServiceCatalog.type(of: "Spotify", override: .other) == .other)
    #expect(ServiceCatalog.type(of: "Gym", override: .video) == .video)
  }
}

@Suite("What can be cancelled")
struct CancelAdvisorTests {
  typealias F = SubFixtures

  private func advice(
    _ payments: [ScheduledPayment], _ subs: SubscriptionBook = .empty,
    options: CancelAdviceOptions = CancelAdviceOptions()
  ) -> CancelAdvice {
    CancelAdvisor.advise(
      lines: F.lines(payments, subs: subs), subscriptions: subs, today: F.today,
      options: options)
  }

  @Test func twoOfAKindAreFoundWithTheirMonthlyCost() throws {
    let yandex = F.subscription("Яндекс Музыка", 299)
    let vk = F.subscription("VK Музыка", 299)
    let gym = F.subscription("Gym", 3_000)
    let result = advice([yandex, vk, gym])
    let group = try #require(result.duplicates.first)
    #expect(result.duplicates.count == 1)
    #expect(group.type == .music)
    #expect(Set(group.paymentIds) == [yandex.id, vk.id])
    #expect(group.monthlyRub == F.rub(598))
    #expect(group.savingYearlyRub == F.rub(3_588))
    #expect(result.savingYearlyRub == F.rub(3_588))
  }

  @Test func keepingBothSilencesTheGroupUntilANewOneAppears() {
    let chat = F.subscription("ChatGPT Plus", 2_000)
    let claude = F.subscription("Claude Pro", 2_000)
    let group = advice([chat, claude]).duplicates[0]
    let kept = CancelAdvisor.keeping(group, in: [])
    let subs = SubscriptionBook(keepGroups: kept)
    #expect(advice([chat, claude], subs).duplicates.isEmpty)
    let third = F.subscription("Gemini Advanced", 2_000)
    let again = advice([chat, claude, third], subs)
    #expect(again.duplicates.count == 1)
    #expect(again.duplicates[0].paymentIds.count == 3)
  }

  @Test func keepingWidensAnExistingGroup() {
    let chat = UUID()
    let claude = UUID()
    let third = UUID()
    let first = CancelAdvisor.keeping(
      DuplicateGroup(
        type: .assistant, paymentIds: [chat, claude], monthlyRub: .zero, savingYearlyRub: .zero),
      in: [])
    let wider = CancelAdvisor.keeping(
      DuplicateGroup(
        type: .assistant, paymentIds: [claude, third], monthlyRub: .zero, savingYearlyRub: .zero),
      in: first)
    #expect(wider.count == 1)
    #expect(wider[0].paymentIds == [chat, claude, third])
  }

  @Test func aNeededSubscriptionIsNeverOffered() {
    let yandex = F.subscription("Яндекс Музыка", 299)
    let vk = F.subscription("VK Музыка", 299)
    let subs = SubscriptionBook(terms: [SubscriptionTerms(paymentId: vk.id, needed: true)])
    #expect(advice([yandex, vk], subs).duplicates.isEmpty)
  }

  @Test func ownersTypeGroupsWhatTheCatalogueDoesNotKnow() {
    let first = F.subscription("Alpha", 100)
    let second = F.subscription("Beta", 100)
    let subs = SubscriptionBook(terms: [
      SubscriptionTerms(paymentId: first.id, serviceType: .video),
      SubscriptionTerms(paymentId: second.id, serviceType: .video),
    ])
    #expect(advice([first, second], subs).duplicates.first?.type == .video)
    let other = SubscriptionBook(terms: [
      SubscriptionTerms(paymentId: first.id, serviceType: .other),
      SubscriptionTerms(paymentId: second.id, serviceType: .other),
    ])
    #expect(advice([first, second], other).duplicates.isEmpty)
  }

  @Test func expensiveAndUnusedIsOfferedOnlyOnceMarksAreKept() {
    let pricey = F.subscription("Pro tool", 1_000)  // 12 000 a year
    let cheap = F.subscription("Small", 100)
    // Nothing marked at all: the owner does not mark, nobody is judged.
    #expect(advice([pricey, cheap]).unused.isEmpty)

    // Marking began long ago, on the cheap one; the pricey one was never marked.
    let marks = [UsageMark(paymentId: cheap.id, day: F.day(7, 1))]
    let subs = SubscriptionBook(usage: marks)
    let result = advice([pricey, cheap], subs)
    #expect(result.unused.map(\.paymentId) == [pricey.id])
    #expect(result.unused[0].lastUsed == nil)
    #expect(result.unused[0].yearlyRub == F.rub(12_000))
    #expect(result.savingYearlyRub == F.rub(12_000))
  }

  @Test func recentMarkKeepsItOut() {
    let pricey = F.subscription("Pro tool", 1_000)
    let subs = SubscriptionBook(usage: [
      UsageMark(paymentId: pricey.id, day: F.day(7, 1)),
      UsageMark(paymentId: pricey.id, day: F.day(9, 30)),
    ])
    #expect(advice([pricey], subs).unused.isEmpty)
  }

  @Test func marksYoungerThanTheWindowDoNotJudgeAnyone() {
    let pricey = F.subscription("Pro tool", 1_000)
    let other = F.subscription("Other", 10)
    let subs = SubscriptionBook(usage: [UsageMark(paymentId: other.id, day: F.day(10, 1))])
    #expect(advice([pricey, other], subs).unused.isEmpty)
  }

  @Test func alreadyCancelledOrNeededIsNotOffered() {
    let ending = F.subscription("Pro tool", 1_000, end: F.day(11, 1))
    let needed = F.subscription("Needed", 1_000)
    let probe = F.subscription("Probe", 10)
    let subs = SubscriptionBook(
      terms: [SubscriptionTerms(paymentId: needed.id, needed: true)],
      usage: [UsageMark(paymentId: probe.id, day: F.day(7, 1))])
    #expect(advice([ending, needed, probe], subs).unused.isEmpty)
  }

  @Test func aSubscriptionInBothListsIsCountedOnceInTheSaving() {
    let yandex = F.subscription("Яндекс Музыка", 1_000)
    let vk = F.subscription("VK Музыка", 900)
    let subs = SubscriptionBook(usage: [UsageMark(paymentId: UUID(), day: F.day(7, 1))])
    let result = advice([yandex, vk], subs)
    #expect(Set(result.unused.map(\.paymentId)) == [yandex.id, vk.id])
    #expect(result.duplicates.count == 1)
    #expect(result.savingYearlyRub == F.rub(22_800))
  }
}

@Suite("Trial and yearly watch")
struct SubscriptionWatchTests {
  typealias F = SubFixtures

  private func notices(
    _ payments: [ScheduledPayment], _ subs: SubscriptionBook = .empty, today: DateOnly = F.today
  ) -> [SubscriptionNotice] {
    SubscriptionWatch.notices(
      book: PlanningBook(scheduled: payments), subscriptions: subs, today: today)
  }

  @Test func trialIsAnnouncedTheDayBefore() throws {
    let film = F.subscription("Film", 399, trialEnd: F.day(10, 15))
    let notice = try #require(notices([film]).first)
    #expect(notice.kind == .trialEnding)
    #expect(notice.day == F.day(10, 15))
    #expect(notice.amount == F.rub(399))
    #expect(notice.notifyOn == F.today)
    #expect(notice.id == "subtrial:\(film.id.uuidString.lowercased()):2026-10-15")
  }

  @Test func trialIsQuietEarlierAndAfterItEnded() {
    let early = F.subscription("Early", 399, trialEnd: F.day(10, 17))
    let past = F.subscription("Past", 399, trialEnd: F.day(10, 13))
    #expect(notices([early, past]).isEmpty)
    #expect(notices([early], today: F.day(10, 16)).count == 1)
    #expect(notices([early], today: F.day(10, 17)).count == 1)
    #expect(notices([early], today: F.day(10, 18)).isEmpty)
  }

  @Test func trialOfACancelledSubscriptionIsQuiet() {
    let film = F.subscription("Film", 399, end: F.day(10, 10), trialEnd: F.day(10, 15))
    #expect(notices([film]).isEmpty)
  }

  @Test func yearlyChargeTwoWeeksAhead() throws {
    let cloud = F.subscription("Cloud", 2_400, freq: .yearly, next: F.day(10, 28))
    let notice = try #require(notices([cloud]).first)
    #expect(notice.kind == .yearlyCharge)
    #expect(notice.day == F.day(10, 28))
    #expect(notice.notifyOn == F.today)
    #expect(notices([cloud], today: F.day(10, 13)).isEmpty)
    #expect(notices([cloud], today: F.day(10, 28)).count == 1)
    #expect(notices([cloud], today: F.day(10, 29)).isEmpty)
  }

  @Test func yearlyReminderCanBeSwitchedOffPerSubscription() {
    let cloud = F.subscription("Cloud", 2_400, freq: .yearly, next: F.day(10, 28))
    let subs = SubscriptionBook(terms: [
      SubscriptionTerms(paymentId: cloud.id, yearlyReminderOff: true)
    ])
    #expect(notices([cloud], subs).isEmpty)
  }

  @Test func monthlySubscriptionsGetNoYearlyNotice() {
    #expect(notices([F.subscription("Music", 299, next: F.day(10, 20))]).isEmpty)
  }

  @Test func yearlyChargeAlreadyPaidIsQuiet() {
    let cloud = F.subscription("Cloud", 2_400, freq: .yearly, next: F.day(10, 28))
    let matches = ScheduledMatches(linked: [cloud.id: [F.day(10, 28)]], matched: [:])
    let result = SubscriptionWatch.notices(
      book: PlanningBook(scheduled: [cloud]), subscriptions: .empty, today: F.today,
      matches: matches)
    #expect(result.isEmpty)
  }

  @Test func noticeIsDismissedByIdAndComesBackWithTheNextOccasion() {
    let cloud = F.subscription("Cloud", 2_400, freq: .yearly, next: F.day(10, 28))
    let first = notices([cloud])[0]
    var next = cloud
    next.nextDate = F.day(10, 28, year: 2027)
    let second = notices([next], today: F.day(10, 20, year: 2027))[0]
    #expect(first.id != second.id)
  }
}

@Suite("Price change: service and rate")
struct PriceChangeSplitTests {
  typealias F = SubFixtures

  @Test func spotifyExample() throws {
    // 10 USD at 90 ₽ = 900; 11 USD at 96.3 ₽ = 1 059.30: +159.30, of which service +90.
    let result = try #require(
      PriceChangeSplits.split(
        oldPrice: F.rub(10), newPrice: F.rub(11), oldRate: 90, newRate: Decimal(string: "96.3")!))
    #expect(result.oldRub == F.rub(900))
    #expect(result.newRub == AmountE4(raw: 10_593_000))
    #expect(result.servicePartRub == F.rub(90))
    #expect(result.ratePartRub == AmountE4(raw: 693_000))
    #expect(result.servicePercent == 10)
    #expect(result.ratePercent == 7)
  }

  @Test func theTwoPartsAlwaysAddUpToTheWhole() throws {
    var seed: UInt64 = 7
    func next(_ bound: UInt64) -> UInt64 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return (seed >> 33) % bound
    }
    for _ in 0..<300 {
      let oldPrice = AmountE4(raw: Int64(next(900_000) + 1_000))
      let newPrice = AmountE4(raw: Int64(next(900_000) + 1_000))
      let oldRate = Decimal(next(20_000) + 1_000) / 100
      let newRate = Decimal(next(20_000) + 1_000) / 100
      let result = try #require(
        PriceChangeSplits.split(
          oldPrice: oldPrice, newPrice: newPrice, oldRate: oldRate, newRate: newRate))
      #expect(result.servicePartRub + result.ratePartRub == result.totalRub)
      #expect(result.totalRub == result.newRub - result.oldRub)
    }
  }

  @Test func onlyTheRateMoved() throws {
    let result = try #require(
      PriceChangeSplits.split(oldPrice: F.rub(10), newPrice: F.rub(10), oldRate: 90, newRate: 99))
    #expect(result.servicePartRub == .zero)
    #expect(result.ratePartRub == F.rub(90))
    #expect(result.servicePercent == 0)
  }

  @Test func cheaperServiceAndWeakerRateGiveNegativeParts() throws {
    let result = try #require(
      PriceChangeSplits.split(oldPrice: F.rub(10), newPrice: F.rub(8), oldRate: 100, newRate: 90))
    #expect(result.totalRub == F.rub(-280))
    #expect(result.servicePartRub == F.rub(-200))
    #expect(result.ratePartRub == F.rub(-80))
  }

  @Test func forAPaymentThroughPricesAndDayRates() throws {
    let payment = F.subscription("Spotify", 10, currency: .usd)
    let prices = [
      SubscriptionPrice(paymentId: payment.id, date: F.day(8, 1), amountE4: F.rub(10)),
      SubscriptionPrice(paymentId: payment.id, date: F.day(10, 1), amountE4: F.rub(11)),
    ]
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: F.day(8, 1), perUnit: 90),
        DayRate(day: F.day(10, 1), perUnit: Decimal(string: "96.3")!),
      ]
    ])
    let result = try #require(
      PriceChangeSplits.split(
        payment: payment, prices: prices, rates: rates, from: F.day(8, 15), to: F.day(10, 14)))
    #expect(result.servicePartRub == F.rub(90))
    #expect(
      PriceChangeSplits.split(
        payment: payment, prices: prices, rates: rates, from: F.day(10, 14), to: F.day(8, 15))
        == nil)
    #expect(
      PriceChangeSplits.split(
        payment: F.subscription("Rub", 10), prices: [], rates: rates, from: F.day(8, 15),
        to: F.day(10, 14)) == nil)
    #expect(
      PriceChangeSplits.split(
        payment: payment, prices: prices, rates: .empty, from: F.day(8, 15), to: F.day(10, 14))
        == nil)
  }
}

@Suite("Floating amounts")
struct FloatingAmountTests {
  typealias F = SubFixtures

  @Test func bandAroundTheCentre() {
    let band = FloatingBand(center: F.rub(4_000), tolerancePercent: 10)
    #expect(band.low == F.rub(3_600))
    #expect(band.high == F.rub(4_400))
    #expect(band.position(of: F.rub(3_600)) == .within)
    #expect(band.position(of: F.rub(4_400)) == .within)
    #expect(band.position(of: F.rub(4_401)) == .above)
    #expect(band.position(of: F.rub(3_599)) == .below)
  }

  @Test func toleranceFromTheHistoryClampedAndDefaulted() {
    let centre = F.rub(4_000)
    #expect(FloatingAmount.tolerance(center: centre, history: []) == 15)
    #expect(FloatingAmount.tolerance(center: centre, history: [F.rub(4_100), F.rub(3_900)]) == 15)
    // Widest distance 9.5 % rounds up to 10.
    let three = [F.rub(4_380), F.rub(3_900), F.rub(4_000)]
    #expect(FloatingAmount.tolerance(center: centre, history: three) == 10)
    // Nearly constant: not narrower than 5 %.
    let flat = [F.rub(4_000), F.rub(4_010), F.rub(3_990)]
    #expect(FloatingAmount.tolerance(center: centre, history: flat) == 5)
    // Wild: not wider than 30 %.
    let wild = [F.rub(1_000), F.rub(9_000), F.rub(4_000)]
    #expect(FloatingAmount.tolerance(center: centre, history: wild) == 30)
    #expect(FloatingAmount.tolerance(center: centre, history: wild, override: 12) == 12)
  }

  @Test func chargeOutsideTheBandIsNewsAndInsideIsNot() throws {
    var utility = F.subscription("Utilities", 4_000)
    utility.kind = .bill
    let terms = SubscriptionTerms(paymentId: utility.id, floating: true, tolerancePercent: 10)
    let subs = SubscriptionBook(terms: [terms])
    let book = PlanningBook(scheduled: [utility])

    let inside = try F.charge(of: utility, on: F.day(10, 5), amount: 4_300)
    let quiet = FloatingAmount.notices(
      book: book, subscriptions: subs, ledger: F.ledger([inside], book: book), today: F.today)
    #expect(quiet.isEmpty)

    let outside = try F.charge(of: utility, on: F.day(10, 12), amount: 5_900)
    let loud = FloatingAmount.notices(
      book: book, subscriptions: subs, ledger: F.ledger([inside, outside], book: book),
      today: F.today)
    let notice = try #require(loud.first)
    #expect(loud.count == 1)
    #expect(notice.kind == .floatingOutside)
    #expect(notice.amount == F.rub(5_900))
    #expect(notice.band?.low == F.rub(3_600))
    #expect(notice.band?.high == F.rub(4_400))
    #expect(notice.id.hasSuffix(outside.transaction.id.uuidString.lowercased()))
  }

  @Test func belowTheBandIsNewsToo() throws {
    let utility = F.subscription("Utilities", 4_000)
    let subs = SubscriptionBook(terms: [
      SubscriptionTerms(paymentId: utility.id, floating: true, tolerancePercent: 10)
    ])
    let book = PlanningBook(scheduled: [utility])
    let low = try F.charge(of: utility, on: F.day(10, 12), amount: 2_000)
    let notices = FloatingAmount.notices(
      book: book, subscriptions: subs, ledger: F.ledger([low], book: book), today: F.today)
    #expect(notices.count == 1)
    #expect(notices[0].band.map { $0.position(of: F.rub(2_000)) } == .below)
  }

  @Test func theBandIsWorkedOutFromTheChargesBeforeTheLatest() throws {
    let utility = F.subscription("Utilities", 4_000)
    let subs = SubscriptionBook(terms: [SubscriptionTerms(paymentId: utility.id, floating: true)])
    let book = PlanningBook(scheduled: [utility])
    let charges = try [
      F.charge(of: utility, on: F.day(7, 5), amount: 3_900),
      F.charge(of: utility, on: F.day(8, 5), amount: 4_100),
      F.charge(of: utility, on: F.day(9, 5), amount: 4_000),
      F.charge(of: utility, on: F.day(10, 5), amount: 6_000),
    ]
    // Before the last: 2.5 % widest → 5 %; 6 000 is far out of 3 800–4 200.
    let notices = FloatingAmount.notices(
      book: book, subscriptions: subs, ledger: F.ledger(charges, book: book), today: F.today)
    #expect(notices.count == 1)
    #expect(notices[0].band?.tolerancePercent == 5)
  }

  @Test func oldNewsAndNonFloatingPaymentsAreQuiet() throws {
    let utility = F.subscription("Utilities", 4_000)
    let book = PlanningBook(scheduled: [utility])
    let old = try F.charge(of: utility, on: F.day(8, 1), amount: 9_000)
    let floating = SubscriptionBook(terms: [
      SubscriptionTerms(paymentId: utility.id, floating: true)
    ])
    #expect(
      FloatingAmount.notices(
        book: book, subscriptions: floating, ledger: F.ledger([old], book: book), today: F.today
      ).isEmpty)
    let recent = try F.charge(of: utility, on: F.day(10, 12), amount: 9_000)
    #expect(
      FloatingAmount.notices(
        book: book, subscriptions: .empty, ledger: F.ledger([recent], book: book),
        today: F.today
      ).isEmpty)
  }

  @Test func aRiseInsideTheBandIsNormal() {
    let band = FloatingBand(center: F.rub(4_000), tolerancePercent: 15)
    #expect(FloatingAmount.isNormal(F.rub(4_500), band: band))
    #expect(!FloatingAmount.isNormal(F.rub(4_700), band: band))
  }
}

@Suite("Calendar of subscriptions")
struct SubscriptionCalendarTests {
  typealias F = SubFixtures

  @Test func comingAndPaidChargesOfSubscriptionsOnly() throws {
    let music = F.subscription("Music", 299, next: F.day(10, 20))
    let cloud = F.subscription("Cloud", 200, next: F.day(10, 3))  // overdue, unpaid
    let rent = ScheduledPayment(
      name: "Rent", kind: .bill, amountE4: F.rub(30_000), day: 25, nextDate: F.day(10, 25))
    var paidMusic = music
    paidMusic.nextDate = F.day(11, 5)
    let book = PlanningBook(scheduled: [music, rent])
    let paid = try F.charge(of: music, on: F.day(10, 5), amount: 299, due: F.day(10, 5))
    let items = SubscriptionCalendar.items(
      in: MonthKey(year: 2026, month: 10), ledger: F.ledger([paid], book: book), book: book,
      today: F.today)
    #expect(items.map(\.day) == [F.day(10, 5), F.day(10, 20)])
    #expect(items.map(\.paid) == [true, false])
    #expect(items.allSatisfy { $0.name == "Music" })
    _ = cloud
    let byDay = SubscriptionCalendar.byDay(items)
    #expect(byDay[F.day(10, 20)]?.count == 1)
  }

  @Test func aFutureMonthShowsOnlyComingCharges() {
    let music = F.subscription("Music", 299, next: F.day(10, 20))
    let book = PlanningBook(scheduled: [music])
    let items = SubscriptionCalendar.items(
      in: MonthKey(year: 2026, month: 12), ledger: F.ledger(book: book), book: book,
      today: F.today)
    #expect(items.map(\.day) == [F.day(12, 20)])
    #expect(items.allSatisfy { !$0.paid })
  }
}

@Suite("App Store billing line")
struct AppStoreBillingTests {
  @Test func recognisesTheAppleLine() {
    #expect(AppStoreBilling.isAppleBilling("APPLE.COM/BILL 899"))
    #expect(AppStoreBilling.isAppleBilling("Itunes.com/bill"))
    #expect(AppStoreBilling.isAppleBilling("App Store"))
    #expect(!AppStoreBilling.isAppleBilling("Netflix"))
    #expect(!AppStoreBilling.isAppleBilling(nil))
  }

  @Test func candidateIsMarkedByItsKey() {
    let apple = SubscriptionCandidate(
      key: SubscriptionCandidates.normalized("APPLE.COM/BILL 899") ?? "", placeId: nil,
      categoryId: nil, currency: .rub, typicalAmount: AmountE4(whole: 899), freq: .monthly,
      occurrences: 3, lastDay: SubFixtures.today)
    #expect(AppStoreBilling.isAppleBilling(apple))
  }
}

@Suite("Stored forms of subscriptions")
struct SubscriptionStorageTests {
  @Test func roundTripsThroughJSONWithStableKeys() throws {
    let id = UUID()
    let book = SubscriptionBook(
      terms: [
        SubscriptionTerms(
          paymentId: id, yearlyPlanE4: AmountE4(whole: 3_000), floating: true,
          tolerancePercent: 12, serviceType: .music, needed: true, ownerUses: false)
      ],
      usage: [UsageMark(paymentId: id, day: SubFixtures.today)],
      users: [SubscriptionUser(paymentId: id, personId: UUID())],
      keepGroups: [KeepGroup(type: .assistant, paymentIds: [id])])
    let data = try JSONEncoder().encode(book)
    #expect(try JSONDecoder().decode(SubscriptionBook.self, from: data) == book)
    let text = String(decoding: data, as: UTF8.self)
    for key in ["payment_id", "yearly_plan_e4", "tolerance_percent", "service_type", "owner_uses"] {
      #expect(text.contains("\"\(key)\""))
    }
  }

  @Test func tableNamesAreStable() {
    #expect(SubscriptionStorage.termsTable == "subscription_terms")
    #expect(SubscriptionStorage.usageTable == "subscription_usage")
    #expect(SubscriptionStorage.usersTable == "subscription_users")
    #expect(SubscriptionStorage.keepGroupsTable == "subscription_keep_groups")
  }
}

@Suite("Subscriptions at scale", .serialized)
struct SubscriptionPerformanceTests {
  typealias F = SubFixtures

  @Test func twoHundredSubscriptionsWithAYearOfMarksAreFast() {
    var payments: [ScheduledPayment] = []
    var marks: [UsageMark] = []
    for index in 0..<200 {
      let payment = F.subscription(
        index % 2 == 0 ? "Spotify \(index)" : "Service \(index)", Int64(100 + index))
      payments.append(payment)
      for offset in stride(from: 0, to: 365, by: 3) {
        marks.append(UsageMark(paymentId: payment.id, day: F.today.adding(days: -offset)))
      }
    }
    let subs = SubscriptionBook(usage: marks)
    let started = Date()
    let lines = F.lines(payments, subs: subs)
    let advice = CancelAdvisor.advise(lines: lines, subscriptions: subs, today: F.today)
    _ = SubscriptionWatch.notices(
      book: PlanningBook(scheduled: payments), subscriptions: subs, today: F.today)
    #expect(lines.count == 200)
    #expect(!advice.duplicates.isEmpty)
    #expect(Date().timeIntervalSince(started) < 2)
  }
}
