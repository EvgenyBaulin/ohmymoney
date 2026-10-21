import CoreAccounting
import CoreKit
import Foundation

/// Writes one synthetic history day by day, oldest first, and keeps its known answers as it
/// goes (`SampleExpectations`): every operation states what it means — my purchase, a
/// refund, a part for a friend that will be written off, a payment that is not spending —
/// and the money lands in the right figure the moment the operation is written.
///
/// One writer writes one set; it is a class only so the many small steps below can share
/// the random source and the output without threading them through every call.
final class SampleHistoryWriter {
  // MARK: - Setting

  private var rng: SeededRandom
  private let calendar: CalendarContext
  private let russian: Bool
  private let density: Int
  private let firstDay: DateOnly
  private let lastDay: DateOnly
  /// The moment the set is made, when the last day is today: nothing is written after it.
  private let now: Date?
  /// Days from the first day to the last one.
  private let span: Int

  // MARK: - Dictionaries

  private var categories: [CoreKit.Category]
  private let categoriesById: [UUID: CoreKit.Category]
  private let named: NamedCategories
  /// The scheduled payments the monthly rent and mobile plan belong to
  /// (`SamplePlanning.rentPaymentId`, `mobilePaymentId`).
  private let rentPaymentId: UUID
  private let mobilePaymentId: UUID
  private let people: Cast
  private let places: Places
  private let mainCard: PaymentMethod
  private let cash: PaymentMethod
  private let travelCard: PaymentMethod
  private let goal: Goal
  private let bankLoan: Debt
  private let phone: Debt
  private let phoneDay: DateOnly?
  private var events: [Event] = []
  private var trips: [Event] = []
  private var birthdays: [DateOnly: Event] = [:]
  private var newYears: [DateOnly: Event] = [:]

  // MARK: - Output

  private var entries: [TransactionEntry] = []
  private var links: [ReimbursementLink] = []
  private var debts: [Debt] = []
  private var debtEntries: [DebtEntry] = []
  private var expectations = SampleExpectations()

  /// The operations of the day being written; they join `entries` in time order.
  private var today: [(moment: Date, order: Int, entry: TransactionEntry)] = []
  private var plan = MonthPlan()
  private var returns: [PendingReturn] = []
  private var refunds: [PendingRefund] = []
  private var phonePayments = 0
  /// Operations written so far, and how many of them I deleted.
  private var written = 0
  private var vanished = 0

  init(
    seed: UInt64, firstDay: DateOnly, lastDay: DateOnly, now: Date? = nil,
    calendar: CalendarContext, language: String, density: Int
  ) {
    var rng = SeededRandom(seed: seed)
    let russian = language.lowercased().hasPrefix("ru")
    self.calendar = calendar
    self.russian = russian
    self.density = density
    self.firstDay = firstDay
    self.lastDay = lastDay
    self.now = now
    let span = daysBetween(firstDay, lastDay, calendar: calendar)
    self.span = span

    // The whole starter tree, system categories included, plus what the dictionaries add
    // under Goals and Loans — the way the app files a goal and a loan.
    var categories = SampleCatalog.makeCategories(language: language) { rng.nextUUID() }
    var lookup: [CategoryKey: CoreKit.Category] = [:]
    for (seed, category) in zip(SampleCatalog.categorySeeds, categories) {
      lookup[CategoryKey(kind: seed.kind, english: seed.english)] = category
    }
    func category(_ english: String, _ kind: CategoryKind = .expense) -> CoreKit.Category {
      guard let found = lookup[CategoryKey(kind: kind, english: english)] else {
        preconditionFailure("missing starter category \(english)")
      }
      return found
    }
    let goalSubcategory = CoreKit.Category(
      id: rng.nextUUID(), parentId: category("Goals").id, kind: .expense,
      name: russian ? "Новый ноутбук" : "New laptop", sort: 0)
    let loanSubcategory = CoreKit.Category(
      id: rng.nextUUID(), parentId: category("Loans").id, kind: .expense,
      name: russian ? "Кредит в банке" : "Bank loan", sort: 0)
    categories += [goalSubcategory, loanSubcategory]
    self.categories = categories
    self.categoriesById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    // Derived, not drawn: asking the random source for it here would shift every draw after
    // it and turn the whole project red.
    self.rentPaymentId = SamplePlanning.rentPaymentId(categories: categories)
    self.mobilePaymentId = SamplePlanning.mobilePaymentId(categories: categories)
    self.named = NamedCategories(
      groceries: category("Groceries"), coffee: category("Coffee shops"),
      restaurants: category("Restaurants"), taxi: category("Taxi"),
      publicTransport: category("Public transport"), fuel: category("Fuel"),
      parking: category("Parking"), fines: category("Fines"), rent: category("Rent"),
      utilities: category("Utilities"), household: category("Household"),
      mobile: category("Mobile"), internet: category("Home internet"),
      aiServices: category("AI services"), pharmacy: category("Pharmacy"),
      clothing: category("Clothing"), electronics: category("Electronics"),
      bars: category("Bars"), cinema: category("Cinema"), gifts: category("Gifts"),
      travel: category("Travel"), fees: category("Fees"), loans: category("Loans"),
      goal: goalSubcategory, loan: loanSubcategory, work: category("Work", .income),
      sideJobs: category("Side jobs", .income), family: category("Family", .income),
      cashback: category("Cashback", .income), interest: category("Interest", .income),
      surcharges: category("Surcharges", .income))

    // An obviously fictional, neutral cast.
    self.people = Cast(
      alex: Person(id: rng.nextUUID(), name: "Alex", relation: .friend),
      robin: Person(id: rng.nextUUID(), name: "Robin", relation: .friend),
      sam: Person(id: rng.nextUUID(), name: "Sam", relation: .partner),
      jordan: Person(id: rng.nextUUID(), name: "Jordan", relation: .family),
      kim: Person(id: rng.nextUUID(), name: "Kim", relation: .family))
    self.places = Places(
      groceries: [
        Place(id: rng.nextUUID(), name: "Green Market"),
        Place(id: rng.nextUUID(), name: "Fresh Corner Grocer"),
      ],
      coffee: [
        Place(id: rng.nextUUID(), name: "Corner Cafe"),
        Place(id: rng.nextUUID(), name: "Riverside Coffee"),
      ],
      dining: [
        Place(id: rng.nextUUID(), name: "Riverside Diner"),
        Place(id: rng.nextUUID(), name: "Old Town Bistro"),
      ],
      bars: [
        Place(id: rng.nextUUID(), name: "Night Owl Bar"),
        Place(id: rng.nextUUID(), name: "Harbor Pub"),
      ],
      electronics: Place(id: rng.nextUUID(), name: "Central Electronics"),
      pharmacy: Place(id: rng.nextUUID(), name: "Sunrise Pharmacy"),
      gifts: Place(id: rng.nextUUID(), name: "Paper Crane Gifts"))
    self.mainCard = PaymentMethod(
      id: rng.nextUUID(), name: "Everyday card", kind: .card, isDefault: true)
    self.cash = PaymentMethod(id: rng.nextUUID(), name: "Cash", kind: .cash)
    self.travelCard = PaymentMethod(id: rng.nextUUID(), name: "Travel card", kind: .card)

    self.goal = Goal(
      id: rng.nextUUID(), name: goalSubcategory.name, targetE4: AmountE4(whole: 150_000),
      monthlyPlanE4: AmountE4(whole: 10_000), subcategoryId: goalSubcategory.id)
    // A loan I had before the app: its payments are my expenses in Loans.
    self.bankLoan = Debt(
      id: rng.nextUUID(), direction: .iOwe, type: .loan, name: loanSubcategory.name,
      monthlyPaymentE4: Self.loanPayment, paymentDay: Self.loanPayday, paymentsAreExpenses: true,
      origin: .existing, loansSubcategoryId: loanSubcategory.id)
    // A phone bought here in instalments: the purchase is the expense, its payments are not.
    let phoneDay =
      Self.phoneOffset <= span ? calendar.adding(days: Self.phoneOffset, to: firstDay) : nil
    self.phoneDay = phoneDay
    self.phone = Debt(
      id: rng.nextUUID(), direction: .iOwe, type: .installment,
      name: russian ? "Новый телефон" : "New phone",
      monthlyPaymentE4: Self.phoneInstalment, paymentDay: min(phoneDay?.day ?? 12, 28),
      paymentsAreExpenses: false, origin: .purchase)
    self.rng = rng

    debts.append(bankLoan)
    let loanBegan = calendar.adding(days: -300, to: firstDay)
    debtEntries.append(
      DebtEntry(
        id: self.rng.nextUUID(), debtId: bankLoan.id, date: loanBegan, description: bankLoan.name,
        amountE4: AmountE4(whole: 500_000), kind: .borrowed))
    payLoanBeforeTheHistory(since: loanBegan)
    planEvents()
  }

  /// The loan began long before the history, and it was paid every month since: one line of the
  /// journal for each payday between the day it began and the first day of the history, the
  /// monthly payment each, with no operation — the operations of those months are not in the
  /// history. Without them every due of those months stood unpaid, and the demo opened its
  /// «Просроченные платежи» with ten rows of the same loan.
  ///
  /// The ids come from a stream of their own, seeded from the loan's: a draw of the history's
  /// would shift every one after it.
  private func payLoanBeforeTheHistory(since began: DateOnly) {
    var stream = SeededRandom(seed: Self.earlierPaymentsSeed(of: bankLoan.id))
    let note = word("Bank loan payment", "Платёж по кредиту")
    var month = began.monthKey
    func payday(of month: MonthKey) -> DateOnly {
      DateOnly(year: month.year, month: month.month, day: Self.loanPayday)
    }
    // The payday of the month it began came before the loan itself: the first due is next month.
    if payday(of: month) < began { month = month.next }
    while payday(of: month) < firstDay {
      debtEntries.append(
        DebtEntry(
          id: stream.nextUUID(), debtId: bankLoan.id, date: payday(of: month), description: note,
          amountE4: -Self.loanPayment, kind: .payment))
      month = month.next
    }
  }

  /// A seed of the early payments' own: the first eight bytes of the loan's id mixed with a tag.
  private static func earlierPaymentsSeed(of loan: UUID) -> UInt64 {
    let tag: UInt64 = 0x4C4F_414E_5041_4944  // "LOANPAID"
    let bytes = loan.uuid
    let high = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
      .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return high ^ tag
  }

  // MARK: - Writing

  func write() -> SampleDataSet {
    var day = firstDay
    var offset = 0
    while day <= lastDay {
      if day == firstDay || day.day == 1 { planMonth(day.monthKey, isFirst: day == firstDay) }
      settleReturns(on: day)
      takeRefunds(on: day)
      monthly(on: day)
      celebrate(on: day)
      guaranteed(offset: offset, on: day)
      for _ in 0..<density { everyday(on: day) }
      if let trip = trips.first(where: { $0.covers(day) }) { travel(on: day, trip) }
      closeDay()
      day = calendar.adding(days: 1, to: day)
      offset += 1
    }

    let templates = [
      Template(
        id: rng.nextUUID(), text: word("coffee 250", "кофе 250"),
        categoryId: named.coffee.id, amountE4: AmountE4(whole: 250), currency: .rub,
        pinned: true, useCount: 42),
      Template(
        id: rng.nextUUID(), text: word("taxi 300", "такси 300"),
        categoryId: named.taxi.id, amountE4: AmountE4(whole: 300), currency: .rub,
        pinned: false, useCount: 11),
      Template(
        id: rng.nextUUID(), text: word("groceries 1500", "продукты 1500"),
        categoryId: named.groceries.id, amountE4: AmountE4(whole: 1_500), currency: .rub,
        pinned: false, useCount: 27),
    ]
    return SampleDataSet(
      categories: categories,
      people: people.all,
      places: places.all,
      paymentMethods: [mainCard, cash, travelCard],
      events: events.sorted { left, right in
        left.startDate != right.startDate
          ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
      },
      templates: templates,
      goals: [goal],
      debts: debts,
      debtEntries: debtEntries,
      entries: entries,
      links: links,
      cashbackCategoryId: named.cashback.id,
      firstDay: firstDay,
      lastDay: lastDay,
      expectations: expectations)
  }

  private func closeDay() {
    today.sort { left, right in
      left.moment != right.moment ? left.moment < right.moment : left.order < right.order
    }
    entries += today.map(\.entry)
    today.removeAll(keepingCapacity: true)
  }

  // MARK: - The calendar of the history

  /// Trips spread over the history, one every 300 days or so; a birthday of my partner and
  /// New Year every year they fall in, each kind in one series so years can be compared.
  private func planEvents() {
    let tripNames = [
      word("Seaside trip", "Поездка на море"), word("Mountain trip", "Поездка в горы"),
      word("City break", "Выходные в другом городе"),
    ]
    if span >= 40 {
      let count = max(1, (span + 1) / 300)
      let segment = (span + 1) / count
      for index in 0..<count {
        let length = rng.int(in: 3...6)
        // Far enough from the end for the money lent abroad to come back inside the range.
        let low = index * segment + 10
        let high = max(low, (index + 1) * segment - length - 20)
        let start = calendar.adding(days: rng.int(in: low...high), to: firstDay)
        let trip = Event(
          id: rng.nextUUID(), name: tripNames[index % tripNames.count], kind: .trip,
          startDate: start, endDate: calendar.adding(days: length, to: start),
          budgetE4: AmountE4(whole: 80_000))
        trips.append(trip)
        events.append(trip)
      }
    }

    if span >= 10 {
      // A date late enough for a year earlier to be inside a history of two years.
      let pick = calendar.adding(days: rng.int(in: (span > 400 ? 380 : 0)...span), to: firstDay)
      let series = rng.nextUUID()
      for year in firstDay.year...lastDay.year {
        let date = DateOnly(year: year, month: pick.month, day: min(pick.day, 28))
        guard date >= firstDay, date <= lastDay else { continue }
        let event = Event(
          id: rng.nextUUID(), name: word("Sam's birthday", "День рождения Сэма"),
          kind: .birthday, startDate: date, endDate: date, budgetE4: AmountE4(whole: 15_000),
          recurringYearly: true, seriesId: series)
        birthdays[date] = event
        events.append(event)
      }
    }

    let series = rng.nextUUID()
    for year in (firstDay.year - 1)...lastDay.year {
      let start = DateOnly(year: year, month: 12, day: 28)
      let end = DateOnly(year: year + 1, month: 1, day: 1)
      let shopping = max(DateOnly(year: year, month: 12, day: 30), firstDay)
      guard shopping <= min(end, lastDay) else { continue }
      let event = Event(
        id: rng.nextUUID(), name: word("New Year", "Новый год"), kind: .newYear,
        startDate: start, endDate: end, budgetE4: AmountE4(whole: 30_000),
        recurringYearly: true, seriesId: series)
      newYears[shopping] = event
      events.append(event)
    }
  }

  private func planMonth(_ month: MonthKey, isFirst: Bool) {
    plan = MonthPlan(
      salaryDay: rng.int(in: 1...3),
      sideJobDay: rng.chance(1, outOf: 3) ? rng.int(in: 12...26) : nil,
      travelCashback: isFirst || rng.chance(1, outOf: 2),
      interest: rng.chance(1, outOf: 2),
      familyDay: rng.chance(1, outOf: 8) ? rng.int(in: 5...25) : nil,
      goalDay: isFirst || rng.chance(3, outOf: 4) ? rng.int(in: 8...12) : nil)
  }

  // MARK: - Monthly life

  private func monthly(on day: DateOnly) {
    let month = day.monthKey
    let previous = month.previous
    if day.day == Self.rentDay {
      // Rent is a scheduled payment, and the app writes the operations of one with the link
      // that explains them. Written as a plain expense it looked like variable spending, and
      // the forecast counted a monthly lump as something that could happen any day.
      emit(
        .expense, on: day, parts: [PartSpec(named.rent, Self.rent)], method: mainCard,
        externalId: OperationLink.scheduled(paymentId: rentPaymentId, due: day).externalId)
    }
    if day.day == plan.salaryDay {
      // Paid on the 1st–3rd for the month before: income belongs to that month.
      emit(
        .income, on: day, parts: [PartSpec(named.work, amount(120_000, 6_000, 60_000))],
        note: word("Salary", "Зарплата"), method: mainCard, periodMonth: previous)
    }
    if day.day == 2 {
      emit(
        .income, on: day, parts: [PartSpec(named.cashback, amount(900, 600, 150))],
        note: word("Cashback", "Кэшбэк"), method: mainCard, periodMonth: previous)
    }
    if day.day == Self.mobileDay {
      // The mobile plan is the other declared bill, paid with its link like the rent. The home
      // internet beside it is no payment of the planning, so it stays a plain expense.
      emit(
        .expense, on: day, parts: [PartSpec(named.mobile, Self.mobile)], method: mainCard,
        externalId: OperationLink.scheduled(paymentId: mobilePaymentId, due: day).externalId)
      emit(.expense, on: day, parts: [PartSpec(named.internet, whole: 750)], method: mainCard)
    }
    if day.day == 10 {
      emit(
        .expense, on: day, parts: [PartSpec(named.utilities, amount(4_500, 1_500, 2_000))],
        method: mainCard)
    }
    if day.day == plan.goalDay {
      var part = PartSpec(named.goal, amount(9_000, 3_000, 3_000))
      part.rating = .goal
      part.goalId = goal.id
      emit(.expense, on: day, parts: [part], note: goal.name, method: mainCard)
    }
    if day.day == 15 {
      // A service billed in dollars: foreign currency outside any trip.
      emit(
        .expense, on: day, currency: .usd, parts: [PartSpec(named.aiServices, whole: 20)],
        method: mainCard)
      if plan.travelCashback {
        emit(
          .income, on: day, parts: [PartSpec(named.cashback, amount(300, 200, 50))],
          note: word("Cashback", "Кэшбэк"), method: travelCard)
      }
    }
    if day.day == plan.sideJobDay {
      emit(
        .income, on: day, parts: [PartSpec(named.sideJobs, amount(18_000, 9_000, 3_000))],
        note: word("Side job", "Подработка"), method: mainCard)
    }
    if day.day == plan.familyDay {
      emit(
        .income, on: day, parts: [PartSpec(named.family, amount(10_000, 5_000, 2_000))],
        note: word("From my parents", "От родителей"), method: mainCard)
    }
    if day.day == 20 {
      emit(
        .income, on: day, parts: [PartSpec(named.work, amount(50_000, 3_000, 30_000))],
        note: word("Advance", "Аванс"), method: mainCard)
    }
    if day.day == Self.loanPayday { payLoan(on: day) }
    if let phoneDay, day.day == phone.paymentDay, day > phoneDay, phonePayments < 6 {
      payPhone(on: day)
    }
    if day.day == calendar.daysInMonth(month), plan.interest {
      emit(
        .income, on: day, parts: [PartSpec(named.interest, amount(500, 300, 100))],
        note: word("Interest", "Проценты"), method: mainCard)
    }
  }

  /// A payment on a debt I had before the app: my expense in its Loans subcategory, and a
  /// line in the debt's journal — what `DebtRules.payment` gives the app. The category is
  /// the application's choice, so its source is `system`, as `DebtRules.paymentDraft` writes it.
  private func payLoan(on day: DateOnly) {
    let note = word("Bank loan payment", "Платёж по кредиту")
    var part = PartSpec(named.loan, Self.loanPayment)
    part.categorySource = .system
    let entry = emit(
      .expense, on: day, parts: [part], note: note, method: mainCard, debtId: bankLoan.id)
    debtEntries.append(
      DebtEntry(
        id: rng.nextUUID(), debtId: bankLoan.id, date: day, description: note,
        amountE4: -Self.loanPayment, kind: .payment, transactionId: entry.id))
  }

  /// A payment for the phone: it only moves the debt, the purchase was the expense. The debt
  /// has no Loans subcategory, so the application files it in the Loans root — `system` too.
  private func payPhone(on day: DateOnly) {
    let note = word("Phone instalment", "Платёж за телефон")
    var part = PartSpec(named.loans, Self.phoneInstalment)
    part.categorySource = .system
    let entry = emit(
      .expense, on: day, parts: [part], note: note, method: mainCard, debtId: phone.id,
      isSpending: false)
    debtEntries.append(
      DebtEntry(
        id: rng.nextUUID(), debtId: phone.id, date: day, description: note,
        amountE4: -Self.phoneInstalment, kind: .payment, transactionId: entry.id))
    phonePayments += 1
  }

  private func buyPhone(on day: DateOnly) {
    let note = word("New phone", "Новый телефон")
    emit(
      .expense, on: day, parts: [PartSpec(named.electronics, Self.phonePrice)],
      note: note, place: places.electronics, method: mainCard, creditDebtId: phone.id)
    debts.append(phone)
    // `DebtRules.creditPurchaseOpening`: the debt starts at the price, with no operation.
    debtEntries.append(
      DebtEntry(
        id: rng.nextUUID(), debtId: phone.id, date: day, description: note,
        amountE4: Self.phonePrice, kind: .borrowed))
  }

  // MARK: - Events

  private func celebrate(on day: DateOnly) {
    if let birthday = birthdays[day] {
      let sam = people.sam
      var gift = PartSpec(named.gifts, amount(5_000, 2_000, 1_500))
      gift.forWhom = .partner
      gift.forPersonId = sam.id
      gift.eventId = birthday.id
      emit(
        .expense, on: day, parts: [gift], note: word("Birthday gift", "Подарок на день рождения"),
        place: places.gifts, method: mainCard)
      var dinner = PartSpec(named.restaurants, amount(6_000, 2_500, 2_500))
      dinner.forWhom = .partner
      dinner.forPersonId = sam.id
      dinner.eventId = birthday.id
      emit(
        .expense, on: day, parts: [dinner], note: word("Birthday dinner", "Ужин в день рождения"),
        place: rng.choice(from: places.dining), method: mainCard)
    }
    if let newYear = newYears[day] {
      for person in [people.jordan, people.kim] {
        var gift = PartSpec(named.gifts, amount(4_000, 2_000, 1_000))
        gift.forWhom = .family
        gift.forPersonId = person.id
        gift.eventId = newYear.id
        emit(
          .expense, on: day, parts: [gift], note: word("New Year gift", "Новогодний подарок"),
          place: places.gifts, method: mainCard)
      }
      var table = PartSpec(named.groceries, amount(7_000, 2_000, 3_000))
      table.forWhom = .family
      table.eventId = newYear.id
      emit(
        .expense, on: day, parts: [table], note: word("New Year table", "Новогодний стол"),
        place: rng.choice(from: places.groceries), method: mainCard)
    }
  }

  private func travel(on day: DateOnly, _ trip: Event) {
    for _ in 0..<density where rng.chance(1, outOf: 2) {
      var spend = PartSpec(named.travel, cents(around: 60, spread: 45, minimum: 5))
      spend.eventId = trip.id
      emit(
        .expense, on: day, currency: rng.choice(from: [CurrencyCode.usd, .eur]), parts: [spend],
        method: travelCard)
    }
    // Dinner with a friend abroad, in dollars; the friend pays back fewer rubles than it
    // cost, so the loss stays with the friend and the trip.
    if day == calendar.adding(days: 1, to: trip.startDate) {
      shareBill(
        on: day, debtor: people.alex, currency: .usd, fate: .returned(.short),
        dueIn: daysBetween(day, trip.endDate, calendar: calendar) + 3, eventId: trip.id)
    }
  }

  // MARK: - Everyday life

  private func everyday(on day: DateOnly) {
    if rng.chance(3, outOf: 7) { buyGroceries(on: day) }
    if rng.chance(4, outOf: 7) { buyCoffee(on: day) }
    if rng.chance(3, outOf: 7) { ride(on: day) }
    if rng.chance(1, outOf: 10) { eatOut(on: day) }
    if rng.chance(1, outOf: 14) { goToTheBar(on: day) }
    if rng.chance(1, outOf: 20) {
      var medicine = PartSpec(named.pharmacy, amount(500, 250, 100))
      uncategorizeNow(&medicine)
      emit(
        .expense, on: day, parts: [medicine], place: places.pharmacy,
        method: rng.chance(1, outOf: 2) ? mainCard : cash)
    }
    if rng.chance(1, outOf: 45) {
      let electronics = rng.chance(1, outOf: 2)
      emit(
        .expense, on: day,
        parts: [
          PartSpec(electronics ? named.electronics : named.clothing, amount(14_000, 7_000, 2_000))
        ],
        place: electronics ? places.electronics : nil, method: mainCard)
    }
    if rng.chance(1, outOf: 50) {
      let fuel = rng.chance(2, outOf: 3)
      var car = PartSpec(
        fuel ? named.fuel : named.parking,
        fuel ? amount(3_000, 1_000, 1_000) : amount(300, 200, 100))
      uncategorizeNow(&car)
      emit(.expense, on: day, parts: [car], method: mainCard)
    }
    if rng.chance(1, outOf: 60) {
      payFine(on: day, contestedAfter: rng.chance(1, outOf: 3) ? rng.int(in: 5...20) : nil)
    }
    if rng.chance(1, outOf: 40) { payFee(on: day) }
    if rng.chance(1, outOf: 30) { orderOnline(on: day) }
    if rng.chance(1, outOf: 30) { buyGift(on: day) }
    if rng.chance(1, outOf: 25) { shareBill(on: day) }
    if rng.chance(1, outOf: 90) { returnPurchase(on: day) }
    if rng.chance(1, outOf: 40) {
      var ticket = PartSpec(named.cinema, amount(700, 300, 300))
      if rng.chance(1, outOf: 2) {
        ticket.forWhom = .partner
        ticket.forPersonId = people.sam.id
      } else {
        uncategorizeNow(&ticket)
      }
      emit(.expense, on: day, parts: [ticket], method: mainCard)
    }
  }

  /// Most shopping is mine; some is for the family or my partner; now and then the
  /// household things bought with it are a second part the panel was never opened for.
  private func buyGroceries(on day: DateOnly, split: Bool? = nil, deleted: Bool = false) {
    var food = PartSpec(named.groceries, amount(1_800, 900, 200))
    if rng.chance(1, outOf: 6) {
      food.forWhom = .family
    } else if rng.chance(1, outOf: 10) {
      food.forWhom = .partner
      food.forPersonId = people.sam.id
    }
    let place = rng.choice(from: places.groceries)
    if split ?? rng.chance(1, outOf: 12) {
      var household = PartSpec(named.household, amount(500, 300, 100))
      household.rating = .unrated
      emit(.expense, on: day, parts: [food, household], place: place, method: mainCard)
      return
    }
    uncategorizeNow(&food)
    emit(
      .expense, on: day, parts: [food], place: place, method: mainCard, mayVanish: true,
      forceDeleted: deleted)
  }

  private func buyCoffee(on day: DateOnly, uncategorized: Bool = false) {
    var coffee = PartSpec(named.coffee, amount(220, 90, 80))
    if uncategorized { coffee.uncategorize() } else { uncategorizeNow(&coffee) }
    emit(
      .expense, on: day, parts: [coffee], place: rng.choice(from: places.coffee),
      method: rng.chance(1, outOf: 2) ? mainCard : cash, mayVanish: true)
  }

  private func ride(on day: DateOnly) {
    let taxi = rng.chance(1, outOf: 3)
    var ride = PartSpec(
      taxi ? named.taxi : named.publicTransport,
      taxi ? amount(350, 150, 40) : amount(60, 30, 40))
    uncategorizeNow(&ride)
    emit(.expense, on: day, parts: [ride], method: mainCard, mayVanish: true)
  }

  private func eatOut(on day: DateOnly, forPartner: Bool? = nil) {
    var meal = PartSpec(named.restaurants, amount(1_900, 800, 400))
    if forPartner ?? rng.chance(1, outOf: 4) {
      meal.forWhom = .partner
      meal.forPersonId = people.sam.id
    } else {
      uncategorizeNow(&meal)
    }
    emit(
      .expense, on: day, parts: [meal], place: rng.choice(from: places.dining), method: mainCard)
  }

  /// Bars sit in a neutral category, and I rate every evening there bad myself.
  private func goToTheBar(on day: DateOnly) {
    var drinks = PartSpec(named.bars, amount(1_500, 700, 300))
    drinks.rating = .byHand(.bad)
    emit(
      .expense, on: day, parts: [drinks], note: word("Evening at the bar", "Вечер в баре"),
      place: rng.choice(from: places.bars), method: rng.chance(1, outOf: 2) ? mainCard : cash)
  }

  /// A fine is bad by its category. Now and then it is contested and the money comes back:
  /// a refund of a bad purchase.
  private func payFine(on day: DateOnly, contestedAfter days: Int?) {
    let fine = amount(1_000, 500, 500)
    emit(
      .expense, on: day, parts: [PartSpec(named.fines, fine)],
      note: word("Parking fine", "Штраф за парковку"), method: mainCard)
    if let days {
      let due = calendar.adding(days: days, to: day)
      if due <= lastDay {
        refunds.append(
          PendingRefund(
            due: due, parts: [PartSpec(named.fines, fine)],
            note: word("Fine cancelled", "Штраф отменён")))
      }
    }
  }

  private func payFee(on day: DateOnly) {
    emit(
      .expense, on: day, parts: [PartSpec(named.fees, amount(150, 100, 30))],
      note: word("Bank fee", "Комиссия банка"), method: mainCard)
  }

  /// An order with a service fee on top: the fee is a second part in Other → Fees that was
  /// never rated, so its quality comes from the rules — bad, like its category.
  private func orderOnline(on day: DateOnly) {
    var fee = PartSpec(named.fees, amount(250, 150, 50))
    fee.rating = .unrated
    emit(
      .expense, on: day, parts: [PartSpec(named.household, amount(2_500, 1_500, 300)), fee],
      note: word("Online order", "Заказ в интернете"), method: mainCard)
  }

  private func buyGift(on day: DateOnly, for person: Person? = nil) {
    let person =
      person ?? rng.choice(from: [people.alex, people.robin, people.jordan, people.kim])
    var gift = PartSpec(named.gifts, amount(2_500, 1_500, 500))
    gift.forWhom = person.relation == .family ? .family : .friends
    gift.forPersonId = person.id
    emit(
      .expense, on: day, parts: [gift], note: word("Gift", "Подарок"), place: places.gifts,
      method: mainCard)
  }

  private func returnPurchase(on day: DateOnly) {
    let groceries = rng.chance(1, outOf: 2)
    emit(
      .refund, on: day,
      parts: [
        PartSpec(groceries ? named.groceries : named.clothing, amount(900, 400, 150))
      ],
      note: word("Refund", "Возврат"), method: mainCard)
  }

  private func takeRefunds(on day: DateOnly) {
    for refund in refunds where refund.due == day {
      emit(.refund, on: day, parts: refund.parts, note: refund.note, method: mainCard)
    }
    refunds.removeAll { $0.due == day }
  }

  /// About 1 % of the parts of purchases are written without a category, and so without a
  /// quality: a little more of the everyday ones, which are most of them.
  private func uncategorizeNow(_ part: inout PartSpec) {
    if rng.chance(1, outOf: 80) { part.uncategorize() }
  }

  // MARK: - Paid for somebody else

  /// What becomes of the part a friend owes.
  enum Fate {
    enum Payback {
      case exact
      /// Fewer rubles come back than the part cost.
      case short
      /// More come back: the rest is a surplus.
      case over
    }

    case returned(Payback)
    case writtenOff
    case waiting
  }

  /// A bill shared with a friend (or with Kim, who is family): my half, and theirs, which
  /// they owe me. Sometimes the part was for somebody other than the one who pays it back —
  /// a ticket for Robin that Alex settles.
  ///
  /// `cancelledAfter` cancels a concert that many days after the friend paid me back: both
  /// tickets come back to my card in one refund. Mine takes my spending back; theirs is
  /// written the way the app writes any part paid for somebody else — reimbursable, with
  /// the friend as debtor — and its refund takes nothing off my spending, since that money
  /// was never mine; I hand it back to the friend.
  private func shareBill(
    on day: DateOnly, debtor: Person? = nil, forSomebodyElse: Bool? = nil,
    currency: CurrencyCode = .rub, tickets: Bool? = nil, fate: Fate? = nil, dueIn: Int? = nil,
    cancelledAfter: Int? = nil, eventId: UUID? = nil
  ) {
    let debtor = debtor ?? rng.choice(from: [people.alex, people.robin, people.kim])
    let tickets = tickets ?? (currency == .rub && rng.chance(1, outOf: 4))
    let category = tickets ? named.cinema : named.restaurants
    let total =
      currency == .rub ? amount(3_200, 1_600, 800) : cents(around: 90, spread: 40, minimum: 30)
    // An odd kopeck splits into halves of x.xx5, as «3201.01/2» typed in the entry line does:
    // stored units hold it, and only the display rounds it.
    let halves = total.split(into: 2)
    var theirs = PartSpec(category, halves[1])
    theirs.forWhom = debtor.relation == .family ? .family : .friends
    theirs.owedBy = debtor.id
    if forSomebodyElse ?? rng.chance(1, outOf: 6) {
      // Robin's ticket that Alex pays back, and the other way round; Kim pays for Jordan.
      theirs.forPersonId =
        debtor.id == people.alex.id
        ? people.robin.id : debtor.id == people.robin.id ? people.alex.id : people.jordan.id
    }
    theirs.eventId = eventId
    var mine = PartSpec(category, halves[0])
    mine.eventId = eventId

    var fate = fate ?? rollFate()
    let due = calendar.adding(days: dueIn ?? rng.int(in: 1...21), to: day)
    if case .returned = fate, due > lastDay { fate = .waiting }
    switch fate {
    case .returned: theirs.status = .returned
    case .writtenOff: theirs.status = .writtenOff
    case .waiting: theirs.status = .expected
    }

    let note =
      eventId != nil
      ? word("Dinner abroad", "Ужин в поездке")
      : tickets
        ? word("Concert tickets", "Билеты на концерт")
        : word("Dinner with friends", "Ужин с друзьями")
    let entry = emit(
      .expense, on: day, currency: currency, parts: [mine, theirs], note: note,
      place: tickets ? nil : rng.choice(from: places.dining),
      method: currency == .rub ? mainCard : travelCard)

    guard case .returned(let payback) = fate else { return }
    if tickets, let cancelledAfter {
      let cancelled = calendar.adding(days: cancelledAfter, to: due)
      if cancelled <= lastDay {
        var theirTicket = PartSpec(category, halves[1])
        theirTicket.forWhom = theirs.forWhom
        theirTicket.forPersonId = theirs.forPersonId
        theirTicket.owedBy = debtor.id
        refunds.append(
          PendingRefund(
            due: cancelled, parts: [mine, theirTicket],
            note: word("Concert cancelled", "Концерт отменён")))
      }
    }
    let part = entry.parts[1]
    let adjustment: AmountE4
    switch payback {
    case .exact: adjustment = .zero
    case .short:
      // 5–15 % less, in whole kopecks.
      let percent = Int64(rng.int(in: 5...15))
      adjustment = -AmountE4(raw: part.amountRubE4.raw * percent / 100 / 100 * 100)
    case .over: adjustment = AmountE4(whole: Int64(rng.int(in: 50...300)))
    }
    returns.append(
      PendingReturn(
        due: due, partId: part.id, occurredAt: entry.transaction.occurredAt,
        month: day.monthKey, rubles: part.amountRubE4, category: category,
        forWhom: part.forWhom, forPersonId: part.forPersonId, debtor: debtor.id,
        eventId: part.eventId, description: part.note ?? entry.transaction.note,
        adjustment: adjustment))
  }

  private func rollFate() -> Fate {
    switch rng.int(in: 0..<20) {
    case 0..<7: .returned(.exact)
    case 7..<9: .returned(.short)
    case 9..<11: .returned(.over)
    case 11..<14: .writtenOff
    default: .waiting
    }
  }

  /// A person pays back everything of theirs that is due today in one reimbursement, the
  /// way the reimbursement sheet records it (`ReimbursementRecording`): the money is spread
  /// over the parts oldest first; every part is closed and linked with what reached it, in
  /// rubles; what is left over is a surplus in Surcharges, and what a part misses is a
  /// shortfall — my expense in its category, with the description, «for whom», person and
  /// event of the purchase. Both point back at the reimbursement through `external_id`.
  private func settleReturns(on day: DateOnly) {
    let due = returns.filter { $0.due == day }
    guard !due.isEmpty else { return }
    returns.removeAll { $0.due == day }
    var debtors: [UUID] = []
    for item in due where !debtors.contains(item.debtor) { debtors.append(item.debtor) }

    for debtor in debtors {
      let parts = due.filter { $0.debtor == debtor }.sorted { left, right in
        left.occurredAt != right.occurredAt
          ? left.occurredAt < right.occurredAt
          : left.partId.uuidString < right.partId.uuidString
      }
      let owed = AmountE4.sum(parts.map(\.rubles))
      let received = max(owed + AmountE4.sum(parts.map(\.adjustment)), AmountE4(whole: 1))
      let now = timestamp(for: day)
      let reimbursementId = rng.nextUUID()
      var payback = PartSpec(nil, received)
      payback.categorySource = .manual
      payback.forPersonId = debtor
      emit(.reimbursement, on: day, at: now, parts: [payback], method: nil, id: reimbursementId)

      var left = received
      var shortfalls: [(part: PendingReturn, amount: AmountE4)] = []
      for part in parts {
        let share = min(left, part.rubles)
        left = left - share
        links.append(
          ReimbursementLink(
            id: rng.nextUUID(), reimbursementTxId: reimbursementId, partId: part.partId,
            amountE4: share))
        let missing = part.rubles - share
        expectations.settle(returned: share, shortfall: missing, purchasedIn: part.month)
        if missing.raw > 0 { shortfalls.append((part, missing)) }
      }
      let key = "reimb:\(reimbursementId.uuidString.lowercased()):"
      if left.raw > 0 {
        var surplus = PartSpec(named.surcharges, left)
        surplus.categorySource = .system
        emit(
          .income, on: day, at: now, parts: [surplus],
          note: word("Surplus of a reimbursement", "Излишек возврата"), method: nil,
          externalId: key + "surplus")
      }
      for (part, missing) in shortfalls {
        var loss = PartSpec(part.category, missing)
        // The application put this category here, not the owner (`ReimbursementRecording`).
        loss.categorySource = .system
        loss.forWhom = part.forWhom
        loss.forPersonId = part.forPersonId ?? part.debtor
        loss.eventId = part.eventId
        emit(
          .expense, on: day, at: now, parts: [loss],
          note: part.description ?? word("Shortfall of a reimbursement", "Недостача возврата"),
          method: nil, externalId: key + "shortfall:" + part.partId.uuidString.lowercased())
      }
    }
  }

  // MARK: - Cases every history has

  /// Every rule gets at least one case on fixed days from the start, whatever the dice say,
  /// so even a short history checks each of them.
  private func guaranteed(offset: Int, on day: DateOnly) {
    switch offset {
    case 1: goToTheBar(on: day)
    case 2: payFine(on: day, contestedAfter: 6)
    case 3: orderOnline(on: day)
    case 4: shareBill(on: day, debtor: people.alex, fate: .returned(.over), dueIn: 4)
    case 5: shareBill(on: day, debtor: people.robin, fate: .returned(.short), dueIn: 5)
    case 6: shareBill(on: day, debtor: people.kim, fate: .writtenOff)
    case 7:
      // Two bills of Alex's, paid back in one go, a little short: the newer one takes the loss.
      shareBill(
        on: day, debtor: people.alex, forSomebodyElse: true, fate: .returned(.exact), dueIn: 7)
    case 8:
      // Robin pays me back for the ticket, then the concert is cancelled.
      shareBill(
        on: day, debtor: people.robin, tickets: true, fate: .returned(.exact), dueIn: 3,
        cancelledAfter: 3)
    case 9: shareBill(on: day, debtor: people.alex, fate: .returned(.short), dueIn: 5)
    case 10: buyGroceries(on: day, split: true)
    case Self.phoneOffset: buyPhone(on: day)
    case 12: buyGift(on: day, for: people.jordan)
    case 13:
      eatOut(on: day, forPartner: true)
      buyGift(on: day, for: people.robin)
    case 15: buyCoffee(on: day, uncategorized: true)
    case 16: buyGroceries(on: day, split: false, deleted: true)
    case 17: returnPurchase(on: day)
    case 18: shareBill(on: day, debtor: people.robin, fate: .waiting)
    default: break
    }
  }

  // MARK: - Writing one operation

  /// One part as the history means it.
  struct PartSpec {
    enum Rating {
      /// The quality of the category, stored — what the ↓ panel gives every part.
      case byCategory
      /// My own rating, stored with source `manual`.
      case byHand(Quality)
      /// No quality stored: the rules decide it when the numbers are made.
      case unrated
      /// A goal contribution: always good, source `system`.
      case goal
    }

    var category: CoreKit.Category?
    var amount: AmountE4
    var rating = Rating.byCategory
    /// The synthetic history stands in for operations the owner typed, so its parts are
    /// filed the way the owner files them — by hand. `system` means the application put the
    /// category there from a rule of its own (a debt payment into Loans, a reimbursement into
    /// Surcharges), and the model is not taught by those.
    var categorySource = CategorySource.manual
    var forWhom = ForWhom.me
    var forPersonId: UUID?
    /// Set for a part paid for somebody else: who owes it.
    var owedBy: UUID?
    var status: ReimbursementStatus?
    var eventId: UUID?
    var goalId: UUID?

    init(_ category: CoreKit.Category?, _ amount: AmountE4) {
      self.category = category
      self.amount = amount
    }

    init(_ category: CoreKit.Category?, whole: Int64) {
      self.init(category, AmountE4(whole: whole))
    }

    mutating func uncategorize() {
      category = nil
      categorySource = .manual
      rating = .unrated
    }
  }

  /// Writes one operation and adds what it means to the known answers. `isSpending` is
  /// false for a payment that only moves a debt; `mayVanish` marks an everyday operation
  /// that can be the one in two hundred I delete.
  @discardableResult
  private func emit(
    _ kind: TransactionKind, on day: DateOnly, at moment: Date? = nil,
    currency: CurrencyCode = .rub, parts specs: [PartSpec], note: String? = nil,
    place: Place? = nil, method: PaymentMethod?, periodMonth: MonthKey? = nil,
    debtId: UUID? = nil, creditDebtId: UUID? = nil, externalId: String? = nil,
    isSpending: Bool = true, mayVanish: Bool = false, forceDeleted: Bool = false,
    id: UUID? = nil
  ) -> TransactionEntry {
    let transactionId = id ?? rng.nextUUID()
    let occurredAt = moment ?? timestamp(for: day)
    let rate = currency == .rub ? nil : Self.rubPerUnit[currency.code]
    var parts: [TransactionPart] = []
    for spec in specs {
      let rubles = rate.map { AmountE4(raw: spec.amount.raw * Self.whole($0)) } ?? spec.amount
      let (quality, source) = stored(spec, kind: kind)
      parts.append(
        TransactionPart(
          id: rng.nextUUID(), transactionId: transactionId, categoryId: spec.category?.id,
          categorySource: spec.categorySource, quality: quality, qualitySource: source,
          amountE4: spec.amount, amountRubE4: rubles, forWhom: spec.forWhom,
          forPersonId: spec.forPersonId, reimbursable: spec.owedBy != nil,
          debtorPersonId: spec.owedBy,
          reimbursementStatus: spec.owedBy == nil ? nil : (spec.status ?? .expected),
          eventId: spec.eventId, goalId: spec.goalId))
    }
    // One operation in two hundred of all of them is deleted. Only everyday ones may vanish
    // — deleting a payment, a bill shared with a friend or a reimbursement would take its
    // debt line or its links with it — and they are only part of the history, a larger
    // part the denser it is. So instead of a roll per operation, the next everyday one
    // vanishes whenever the history falls behind that share: it holds at any density.
    let deleted = forceDeleted || (mayVanish && (vanished + 1) * 200 <= written + 1)
    written += 1
    if deleted { vanished += 1 }
    var deletedAt = deleted ? occurredAt.addingTimeInterval(3_600) : nil
    // Deleted within the hour, but never after the set is made.
    if let now, let moment = deletedAt, moment > now { deletedAt = max(now, occurredAt) }
    let entry = TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: occurredAt, currency: currency,
        amountE4: AmountE4.sum(parts.map(\.amountE4)), rate: rate,
        rateDate: rate == nil ? nil : day, rateSource: rate == nil ? nil : .manual,
        amountRubE4: AmountE4.sum(parts.map(\.amountRubE4)), note: note, placeId: place?.id,
        paymentMethodId: method?.id, periodMonth: periodMonth, debtId: debtId,
        creditDebtId: creditDebtId, externalId: externalId,
        // Pinned to the operation's own moment, so the same seed gives the same bytes.
        createdAt: occurredAt, updatedAt: deletedAt ?? occurredAt, deletedAt: deletedAt),
      parts: parts)
    today.append((occurredAt, today.count, entry))
    if !deleted {
      record(entry, specs: specs, day: day, isSpending: isSpending)
    }
    return entry
  }

  /// What the operation means for the known answers. Deleted operations never get here.
  private func record(
    _ entry: TransactionEntry, specs: [PartSpec], day: DateOnly, isSpending: Bool
  ) {
    let month = day.monthKey
    let transaction = entry.transaction
    for (part, spec) in zip(entry.parts, specs) {
      let root = spec.category.map { $0.parentId ?? $0.id }
      let quality = part.quality ?? ruleQuality(of: spec.category)
      switch transaction.kind {
      case .expense:
        guard isSpending else { continue }
        if let status = part.reimbursementStatus, part.reimbursable {
          // Not mine unless written off; a returned one is settled with its reimbursement.
          expectations.payForOthers(part.amountRubE4, in: month, status: status)
          if status == .writtenOff {
            expectations.spend(part.amountRubE4, in: month, root: root, quality: quality)
          }
        } else {
          expectations.spend(part.amountRubE4, in: month, root: root, quality: quality)
        }
      case .refund:
        // A part bought for somebody else and taken back — a friend's ticket to a cancelled
        // concert: that money was never mine, so its refund leaves my spending alone.
        guard spec.owedBy == nil else { continue }
        expectations.spend(-part.amountRubE4, in: month, root: root, quality: quality)
      case .income:
        expectations.receive(
          part.amountRubE4, for: transaction.periodMonth ?? month,
          cashbackTo: spec.category?.id == named.cashback.id ? transaction.paymentMethodId : nil,
          isSurplus: spec.category?.id == named.surcharges.id)
      case .reimbursement:
        // Money given back is neither income nor spending.
        continue
      }
    }
  }

  private func stored(_ spec: PartSpec, kind: TransactionKind) -> (Quality?, QualitySource?) {
    guard kind == .expense || kind == .refund else { return (nil, nil) }
    switch spec.rating {
    case .byCategory: return (ruleQuality(of: spec.category), .category)
    case .byHand(let quality): return (quality, .manual)
    case .unrated: return (nil, nil)
    case .goal: return (.good, .system)
    }
  }

  /// The quality the rules give a part of this category: its own, else its parent's, else
  /// neutral. None of the descriptions of unrated parts is ever rated by hand, so my
  /// history never overrides it here.
  private func ruleQuality(of category: CoreKit.Category?) -> Quality {
    guard let category else { return .neutral }
    if let quality = category.quality { return quality }
    return category.parentId.flatMap { categoriesById[$0]?.quality } ?? .neutral
  }

  // MARK: - Small helpers

  private func word(_ english: String, _ russian: String) -> String {
    self.russian ? russian : english
  }

  /// Rubles scattered around `center`, in whole kopecks, never below `minimum`.
  private func amount(_ center: Int64, _ spread: Int64, _ minimum: Int64) -> AmountE4 {
    let value = rng.amount(around: AmountE4(whole: center), spread: AmountE4(whole: spread))
    let kopecks = AmountE4(raw: value.raw / 100 * 100)
    return max(kopecks, AmountE4(whole: minimum))
  }

  /// The same for a foreign currency, in whole cents.
  private func cents(around center: Int64, spread: Int64, minimum: Int64) -> AmountE4 {
    amount(center, spread, minimum)
  }

  /// A plausible time of day, so the operations of one day do not all land on midnight.
  private func timestamp(for day: DateOnly) -> Date {
    let seconds = rng.int(in: 7...22) * 3_600 + rng.int(in: 0...59) * 60
    return calendar.startOfDay(day).addingTimeInterval(TimeInterval(livedSoFar(seconds, on: day)))
  }

  /// A time drawn over 07:00–22:59, pressed into the part of the last day lived before `now`:
  /// between 07:00 and `now` once the morning has come, between midnight and `now` before
  /// it. The draws stay the same, and so does their order.
  private func livedSoFar(_ seconds: Int, on day: DateOnly) -> Int {
    guard day == lastDay, let now else { return seconds }
    let elapsed = max(0, Int(now.timeIntervalSince(calendar.startOfDay(day))))
    let open = 7 * 3_600
    let close = 23 * 3_600
    guard elapsed < close else { return seconds }
    guard elapsed > open else { return seconds * elapsed / close }
    return open + (seconds - open) * (elapsed - open) / (close - open)
  }

  /// Fixed, approximate rates, only to give synthetic foreign spending a plausible ruble
  /// figure — never fetched, never real market data. Whole rubles, so a part converts
  /// exactly and the parts of an operation add up in rubles too.
  private static let rubPerUnit: [String: Decimal] = ["USD": 95, "EUR": 103]

  private static func whole(_ rate: Decimal) -> Int64 {
    (try? DecimalMath.int64(rounding: rate)) ?? 1
  }

  /// The rent and the mobile plan, paid on the same day every month: the sample's planning
  /// schedules them as they are (`SamplePlanning`).
  static let rentDay = 1
  static let rent = AmountE4(whole: 45_000)
  static let mobileDay = 7
  static let mobile = AmountE4(whole: 650)

  private static let loanPayment = AmountE4(whole: 15_000)
  private static let loanPayday = 25
  private static let phoneInstalment = AmountE4(whole: 8_000)
  private static let phonePrice = AmountE4(whole: 48_000)
  private static let phoneOffset = 11

  // MARK: - Types

  private struct CategoryKey: Hashable {
    let kind: CategoryKind
    let english: String
  }

  private struct NamedCategories {
    let groceries, coffee, restaurants, taxi, publicTransport, fuel, parking,
      fines: CoreKit.Category
    let rent, utilities, household, mobile, internet, aiServices, pharmacy: CoreKit.Category
    let clothing, electronics, bars, cinema, gifts, travel, fees, loans: CoreKit.Category
    let goal, loan: CoreKit.Category
    let work, sideJobs, family, cashback, interest, surcharges: CoreKit.Category
  }

  private struct Cast {
    let alex, robin, sam, jordan, kim: Person
    var all: [Person] { [alex, robin, sam, jordan, kim] }
  }

  private struct Places {
    let groceries, coffee, dining, bars: [Place]
    let electronics, pharmacy, gifts: Place
    var all: [Place] { groceries + coffee + dining + bars + [electronics, pharmacy, gifts] }
  }

  private struct MonthPlan {
    var salaryDay = 1
    var sideJobDay: Int?
    var travelCashback = false
    var interest = false
    var familyDay: Int?
    var goalDay: Int?
  }

  private struct PendingReturn {
    let due: DateOnly
    let partId: UUID
    let occurredAt: Date
    /// The month of the purchase: what comes back counts there.
    let month: MonthKey
    let rubles: AmountE4
    let category: CoreKit.Category?
    let forWhom: ForWhom
    let forPersonId: UUID?
    let debtor: UUID
    let eventId: UUID?
    let description: String?
    /// Rubles on top of the part (a surplus) or missing from it (a shortfall).
    let adjustment: AmountE4
  }

  private struct PendingRefund {
    let due: DateOnly
    let parts: [PartSpec]
    let note: String
  }
}

/// Whole days between two calendar days.
func daysBetween(_ start: DateOnly, _ end: DateOnly, calendar: CalendarContext) -> Int {
  let seconds = calendar.startOfDay(end).timeIntervalSince(calendar.startOfDay(start))
  return Int((seconds / 86_400).rounded())
}
