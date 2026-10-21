import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// A debt that has none of the terms the credits brought — dues every few days, parts, a markup,
/// an early repayment, a pledge — counts exactly as it did before them: its dues, its schedule,
/// the debts screen, the free sum and the capital. The figures of a sample with every feature and
/// of debts drawn at random are written out as text, and the digest of that text was taken on
/// the code before the credits changed any rule: a rule that moves a figure of an old debt turns
/// this red.
///
/// When a change is meant to move the figures of an old debt, it is not a debt of the older kind
/// any more: say why in the commit and put the digest the failure prints here.
@Suite("Debts without the new terms count as they did")
struct DebtsCountAsBeforePropertyTests {
  static let calendar = CalendarContext.moscow
  static let lastDays = [
    DateOnly(year: 2026, month: 10, day: 12), DateOnly(year: 2027, month: 2, day: 28),
    DateOnly(year: 2027, month: 7, day: 6),
  ]
  /// The digest of the figures, one per last day, taken before the credits changed any rule.
  static let digests = [
    "2026-10-12": "87ffde9d59f512d2", "2027-02-28": "78ab8b494a22f75",
    "2027-07-06": "63e4c9026246cb28",
  ]

  /// The sample through the capital — before the layers that bring debts of the new kinds —, and
  /// a dozen debts drawn at random beside its own.
  static func dataset(lastDay: DateOnly, seed: UInt64) -> Dataset {
    let set = SampleDataGenerator(seed: 20_261_012).generate(
      months: 6, endingOn: lastDay, calendar: calendar, language: "ru"
    ).withAccounts(seed: 20_261_012, calendar: calendar, language: "ru")
      .withLayersThroughTheCapital(
        seed: 20_261_012, calendar: calendar, language: "ru", now: nil, demo: false)
    var random = Random(seed: seed)
    var debts = set.debts
    var journal = set.debtEntries
    for _ in 0..<12 {
      let (debt, lines) = drawn(&random, lastDay: lastDay)
      debts.append(debt)
      journal += lines
    }
    var planning = set.planningBook
    planning.debtEntries = journal
    return Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods, debts: debts,
      goals: set.goals, planning: planning,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, assets: set.assets,
      assetValuations: set.assetValuations)
  }

  /// A debt of the older kind: a loan, a purchase on credit, a personal debt either way, with
  /// or without a monthly payment and a day, borrowed some months ago and paid in uneven sums.
  static func drawn(_ random: inout Random, lastDay: DateOnly) -> (Debt, [DebtEntry]) {
    let direction: DebtDirection = random.next(2) == 0 ? .iOwe : .owedToMe
    let types: [DebtType] = [.loan, .installment, .personal, .creditCard]
    let type = types[random.next(types.count)]
    let origin: DebtOrigin = direction == .iOwe && random.next(3) == 0 ? .purchase : .existing
    let monthly = random.next(4) == 0 ? nil : AmountE4(whole: Int64(1_000 + random.next(20_000)))
    let day = random.next(5) == 0 ? nil : 1 + random.next(31)
    let debt = Debt(
      id: random.uuid(), direction: direction, type: type, name: "Debt \(random.next(1_000))",
      interestRate: random.next(3) == 0 ? Decimal(string: "12.9") : nil,
      monthlyPaymentE4: monthly, paymentDay: day,
      paymentsAreExpenses: origin == .existing, origin: origin, closed: random.next(10) == 0)
    let start = lastDay.adding(days: -(30 + random.next(300)))
    let borrowed = AmountE4(whole: Int64(10_000 + random.next(200_000)))
    var lines = [
      DebtEntry(
        id: random.uuid(), debtId: debt.id, date: start, amountE4: borrowed, kind: .borrowed)
    ]
    var day0 = start
    for _ in 0..<random.next(9) {
      day0 = day0.adding(days: 10 + random.next(40))
      guard day0 <= lastDay.adding(days: 20) else { break }
      let paid = AmountE4(whole: Int64(500 + random.next(25_000)))
      lines.append(
        DebtEntry(
          id: random.uuid(), debtId: debt.id, date: day0, amountE4: -paid, kind: .payment,
          closesTerm: random.next(6) == 0))
    }
    return (debt, lines)
  }

  /// Every figure the rules give of the debts, of the free sum and of the capital, as text.
  static func figures(lastDay: DateOnly, seed: UInt64) -> String {
    let dataset = dataset(lastDay: lastDay, seed: seed)
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let now = calendar.startOfDay(lastDay).addingTimeInterval(20 * 3_600)
    let rubPerUnit: [CurrencyCode: Decimal] = [.usd: 95, .eur: 103]
    var text = ""
    func line(_ parts: Any...) { text += parts.map { "\($0)" }.joined(separator: "|") + "\n" }
    func amount(_ value: AmountE4?) -> String { value.map { String($0.raw) } ?? "-" }
    func day(_ value: DateOnly?) -> String { value?.iso ?? "-" }
    func steps(_ instalments: DebtInstalments) -> String {
      instalments.steps.map { "\($0.fromIndex):\($0.amountE4.raw)" }.joined(separator: ",")
    }

    let debts = dataset.debts.sorted { $0.id.uuidString < $1.id.uuidString }
    let states = DebtDues.states(
      debts: debts, ledger: ledger, journal: dataset.planning.debtEntries, today: lastDay)
    for debt in debts {
      guard let state = states[debt.id] else {
        line("no state", debt.id)
        continue
      }
      line(
        "dues", debt.id, day(state.firstDue), state.paidCount, amount(state.partialE4), state.owes,
        state.paymentDay, amount(state.balanceE4), amount(state.monthlyE4),
        steps(state.instalments), (0..<4).map { amount(state.amount(ofDue: $0)) },
        state.overdue(today: lastDay).map(\.iso), day(state.firstUnpaid))
      if let first = state.firstDue, let paymentDay = debt.paymentDay {
        let plan = DebtSchedulePlan.plan(
          debt: debt, journal: dataset.planning.debtEntries, firstDue: first,
          paymentDay: paymentDay, today: lastDay, calendar: calendar)
        line(
          "plan", debt.id, steps(plan.instalments), plan.mainIndex ?? -1, amount(plan.mainAmount),
          amount(plan.deferredE4))
      }
    }

    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: lastDay, now: now, rubPerUnit: rubPerUnit)
    let overview = snapshot.debts
    for debtLine in overview.iOwe + overview.closed {
      line(
        "line", debtLine.debt.id, amount(debtLine.balance), amount(debtLine.balanceRub),
        day(debtLine.nextPayment), debtLine.paidThisMonth, amount(debtLine.accruedInterestE4))
    }
    line(
      "overview", amount(overview.totalIOweRub), amount(overview.totalOwedToMeRub),
      amount(overview.monthlyPaymentsRub), overview.withoutRate.map(\.uuidString).sorted(),
      overview.owedToMe.count)
    for free in [
      snapshot.freeMoney,
      snapshot.freeMoney(until: lastDay.monthKey.adding(months: 3).lastDay, ledger: ledger),
    ] {
      line(
        "free", day(free.until), amount(free.moneyNow), amount(free.main), amount(free.grey),
        amount(free.dailyGuide), amount(free.overdue),
        free.lines.map { "\($0.key)\($0.sign)\($0.amount.raw)" })
      let plan = free.plan
      line(
        "plan", amount(plan.scheduled), amount(plan.debts), amount(plan.goalSavings),
        amount(plan.goalPlans), amount(plan.events), amount(plan.overdue),
        plan.scheduledDueCount, plan.debtDueCount)
    }
    for point in snapshot.capital.points + [snapshot.capital.now] {
      line(
        "capital", day(point.day), point.isNow, amount(point.accountsRub),
        amount(point.depositsRub), amount(point.outOfSummaryRub), amount(point.assetsRub),
        amount(point.owedToMeRub), amount(point.iOweRub), amount(point.cushionRub))
    }
    return text
  }

  /// FNV-1a over the bytes of the text: the same text, the same digest on every platform.
  static func digest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  @Test(arguments: lastDays)
  func theFiguresOfOldDebtsStayAsTheyWere(_ lastDay: DateOnly) {
    let text = Self.figures(lastDay: lastDay, seed: 1_908)
    #expect(text.contains("dues|"), "no debt was counted")
    #expect(text.contains("plan|"), "no schedule was counted")
    #expect(Self.figures(lastDay: lastDay, seed: 1_908) == text, "the figures are not stable")
    let found = Self.digest(text)
    #expect(
      found == Self.digests[lastDay.iso],
      "\(lastDay.iso): the figures of old debts moved (digest \(found), \(text.count) characters)")
  }

  /// SplitMix64: the drawn debts are the same on every platform and every run.
  struct Random {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next64() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    mutating func next(_ bound: Int) -> Int { Int(next64() % UInt64(bound)) }

    mutating func uuid() -> UUID {
      let high = next64()
      let low = next64()
      var bytes = [UInt8](repeating: 0, count: 16)
      for index in 0..<8 {
        bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * index))
        bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (8 * index))
      }
      return UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
  }
}
