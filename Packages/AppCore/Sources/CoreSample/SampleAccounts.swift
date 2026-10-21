import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The history the way accounts keep it, with no random draw: every account says which
  /// currencies it holds, every operation names its account, and one in a currency its account
  /// does not hold says what the account was charged.
  ///
  /// * An account that states no currency holds rubles; the cash and the card for foreign money
  ///   hold dollars too.
  /// * An operation without an account — money given back, its surplus and shortfalls — is on
  ///   the main account.
  /// * An operation in a currency its ruble account does not hold was charged its rubles: a
  ///   charge in rubles is the operation's rubles, so no ruble figure of the history moves.
  ///
  /// None of this changes what was drawn — ids, moments, currencies, amounts, categories — so
  /// the history's own digest and known answers stay as they are. Doing it twice changes
  /// nothing more.
  public func assigningAccounts() -> SampleDataSet {
    var set = self
    set.paymentMethods = paymentMethods.map { account in
      guard account.currency == nil else { return account }
      var account = account
      account.currency = .rub
      if !account.isDefault, account.kind == .cash || account.kind == .card,
        !account.otherCurrencies.contains(.usd)
      {
        account.otherCurrencies.append(.usd)
      }
      return account
    }
    let accounts = Dictionary(
      set.paymentMethods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let main = set.paymentMethods.first { $0.isDefault && !$0.archived }
    set.entries = entries.map { entry in
      var entry = entry
      if entry.transaction.paymentMethodId == nil, let main {
        entry.transaction.paymentMethodId = main.id
      }
      let transaction = entry.transaction
      guard transaction.accountCurrency == nil, let id = transaction.paymentMethodId,
        let account = accounts[id], !account.holds(transaction.currency),
        account.mainCurrency == .rub, transaction.amountRubE4.raw > 0
      else { return entry }
      entry.transaction.accountCurrency = .rub
      entry.transaction.accountAmountE4 = transaction.amountRubE4
      return entry
    }
    return set
  }

  /// The history with accounts, as the owner of an app with accounts would have it: groups,
  /// accounts in several currencies, transfers, counts, refunds tied to their purchases, money
  /// back that covers only part of a debt, a payment due once, a goal in dollars, budgets of the
  /// coming events and money borrowed through a debt journal.
  ///
  /// It draws from random streams of its own (`seed` mixed with a tag), so the history under
  /// it — its digest, its known answers, the golden figures, the fixtures of `make eval-model`
  /// — is exactly what `SampleDataGenerator.generate` gave. Every feature sits on a fixed day
  /// from the first day of the history, or on the same day of every month, so any seed has
  /// all of it once the history is long enough; what would fall on the last day or after it is
  /// left out, so nothing comes after `now`. Each row draws from a stream keyed by its feature
  /// and its day, so a history that ends on another day, or is of another length, has the same
  /// row wherever the two share a day: the Debug menu writes a sample again over its own rows.
  ///
  /// The operations it adds join the known answers (`expectations`) as it writes them, and the
  /// money of every account and currency at the end is kept in `accountExpectations`.
  /// Applied once: a set that already has groups of accounts comes back as it is.
  public func withAccounts(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date? = nil
  ) -> SampleDataSet {
    guard accountGroups.isEmpty else { return self }
    let assigned = assigningAccounts()
    guard
      let writer = SampleAccountsWriter(
        set: assigned, seed: seed, calendar: calendar, language: language, now: now)
    else { return assigned }
    return writer.write()
  }
}

/// Writes the accounts layer over one history. A class only so the many small steps can share
/// the output.
final class SampleAccountsWriter {
  // MARK: - Setting

  /// The seed of the layer's streams: the set's own, mixed with a tag.
  private let layerSeed: UInt64
  private let calendar: CalendarContext
  private let russian: Bool
  private let now: Date?
  private let base: SampleDataSet
  /// Days from the first day of the history to the last one.
  private let span: Int
  private let categoriesById: [UUID: CoreKit.Category]

  // MARK: - Rows the layer adds or changes

  private let russia: AccountGroup
  private let kazakhstan: AccountGroup
  private let everyday: PaymentMethod
  private let cash: PaymentMethod
  private let travel: PaymentMethod
  private let multi: PaymentMethod
  private let tenge: PaymentMethod
  private let reconcileExpense: CoreKit.Category
  private let reconcileIncome: CoreKit.Category
  private let tripCategory: CoreKit.Category
  private let taylor: Person
  private let market: Place
  private let cafe: Place
  private var tripGoal: Goal
  private let familyLoan: Debt
  private let lender: Person
  private let named: Named
  private let events: [Event]
  private let oneOff: ScheduledPayment
  private let openingId: UUID
  private let openingBalanceIds: [UUID]
  private let sheetId: UUID
  private let sheetBalanceIds: [UUID]
  private let differenceId: UUID
  private let differencePartId: UUID
  private let loanLineId: UUID

  // MARK: - Output

  private var added: [TransactionEntry] = []
  private var transfers: [Transfer] = []
  private var links: [ReimbursementLink] = []
  private var debtEntries: [DebtEntry] = []
  private var expectations: SampleExpectations

  init?(
    set: SampleDataSet, seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) {
    let starter = StarterCategories(set.categories)
    let byId = Dictionary(
      set.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func category(_ english: String, _ kind: CategoryKind = .expense) -> CoreKit.Category? {
      starter.id(english, kind).flatMap { byId[$0] }
    }
    guard let main = set.paymentMethods.first(where: { $0.isDefault && !$0.archived }),
      let cash = set.paymentMethods.first(where: { $0.kind == .cash && !$0.isDefault }),
      let travel = set.paymentMethods.first(where: { $0.kind == .card && !$0.isDefault }),
      let goals = set.categories.first(where: { $0.systemRole == .goals && $0.kind == .expense }),
      let lender = set.people.first(where: { $0.relation == .family }),
      let groceries = category("Groceries"), let coffee = category("Coffee shops"),
      let taxi = category("Taxi"), let electronics = category("Electronics"),
      let clothing = category("Clothing"), let household = category("Household"),
      let restaurants = category("Restaurants"), let hosting = category("Hosting"),
      let fees = category("Fees"), let repairs = category("Repairs")
    else { return nil }

    let layerSeed = seed ^ 0x0011_ACC0_0000_0011
    self.layerSeed = layerSeed
    var rng = SeededRandom(seed: layerSeed)
    let russian = language.lowercased().hasPrefix("ru")
    func word(_ english: String, _ russianText: String) -> String {
      russian ? russianText : english
    }
    self.calendar = calendar
    self.russian = russian
    self.now = now
    self.base = set
    self.span = daysBetween(set.firstDay, set.lastDay, calendar: calendar)
    self.lender = lender
    self.named = Named(
      groceries: groceries, coffee: coffee, taxi: taxi, electronics: electronics,
      clothing: clothing, household: household, restaurants: restaurants, hosting: hosting,
      fees: fees, repairs: repairs, goals: goals)
    self.expectations = set.expectations

    // Everything drawn here is drawn whatever the length of the history, so the accounts, the
    // categories and the people keep their ids from one length to another. The group in the
    // summary comes first, whatever the names.
    let russia = AccountGroup(id: rng.nextUUID(), name: word("Russia", "Россия"), sort: 1)
    let kazakhstan = AccountGroup(
      id: rng.nextUUID(), name: word("Kazakhstan", "Казахстан"), inSummary: false, sort: 2)
    self.russia = russia
    self.kazakhstan = kazakhstan
    var everyday = main
    everyday.name = word("Everyday card", "Повседневная карта")
    everyday.groupId = russia.id
    var cashAccount = cash
    cashAccount.name = word("Cash", "Наличные")
    cashAccount.groupId = russia.id
    var travelAccount = travel
    travelAccount.name = word("Travel card", "Карта для поездок")
    travelAccount.groupId = russia.id
    self.everyday = everyday
    self.cash = cashAccount
    self.travel = travelAccount
    // Like «Freedom»: euros first, then dollars, rubles and tenge.
    self.multi = PaymentMethod(
      id: rng.nextUUID(), name: word("Multi-currency account", "Мультивалютный счёт"),
      kind: .account, currency: .eur, groupId: kazakhstan.id,
      otherCurrencies: [.usd, .rub, Self.kzt])
    self.tenge = PaymentMethod(
      id: rng.nextUUID(), name: word("Tenge card", "Карта в тенге"), kind: .card,
      currency: Self.kzt, groupId: kazakhstan.id)

    // The categories the app makes the first time a difference is recorded, top level and
    // neutral, and the one a new goal gets under Goals.
    let topSort = (set.categories.filter { $0.parentId == nil }.map(\.sort).max() ?? 0) + 1
    self.reconcileExpense = CoreKit.Category(
      id: rng.nextUUID(), parentId: nil, kind: .expense,
      name: word("Reconciliation", "Сверка"), sort: topSort, quality: .neutral)
    self.reconcileIncome = CoreKit.Category(
      id: rng.nextUUID(), parentId: nil, kind: .income,
      name: word("Reconciliation", "Сверка"), sort: topSort)
    let underGoals = set.categories.filter { $0.parentId == goals.id }.map(\.sort).max() ?? -1
    let tripCategory = CoreKit.Category(
      id: rng.nextUUID(), parentId: goals.id, kind: .expense,
      name: word("Trip fund", "Поездка"), sort: underGoals + 1)
    self.tripCategory = tripCategory
    self.categoriesById = byId.merging(
      [self.reconcileExpense, self.reconcileIncome, tripCategory].map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    self.taylor = Person(id: rng.nextUUID(), name: "Taylor", relation: .friend)
    self.market = Place(id: rng.nextUUID(), name: "Steppe Market")
    self.cafe = Place(id: rng.nextUUID(), name: "Silk Road Cafe")
    self.tripGoal = Goal(
      id: rng.nextUUID(), name: tripCategory.name, targetE4: AmountE4(whole: 1_500),
      monthlyPlanE4: AmountE4(whole: 150), subcategoryId: tripCategory.id, currency: .usd)
    self.familyLoan = Debt(
      id: rng.nextUUID(), direction: .iOwe, type: .personal,
      name: word("Family loan", "Заём у родных"), personId: lender.id,
      paymentsAreExpenses: false, origin: .existing)

    // The coming birthday and the New Year under way or coming, with their budgets, in the
    // series of the history.
    let birthdayId = rng.nextUUID()
    let newYearId = rng.nextUUID()
    let birthdaySeries = rng.nextUUID()
    let newYearSeries = rng.nextUUID()
    self.events = Self.comingEvents(
      after: set.lastDay, in: set.events, ids: (birthdayId, newYearId),
      series: (birthdaySeries, newYearSeries),
      names: (word("Sam's birthday", "День рождения Сэма"), word("New Year", "Новый год")))

    let dueOnce = calendar.adding(days: 12, to: set.lastDay)
    self.oneOff = ScheduledPayment(
      id: rng.nextUUID(), name: word("Washing machine repair", "Ремонт стиральной машины"),
      kind: .bill, amountE4: AmountE4(whole: Int64(rng.int(in: 60...120)) * 100),
      categoryId: repairs.id, paymentMethodId: everyday.id, day: dueOnce.day,
      nextDate: dueOnce, endDate: dueOnce, remindDaysBefore: 3)

    // Every key has a count at the opening and at the sheet: ten of them.
    let keyCount = [everyday, cashAccount, travelAccount, multi, tenge]
      .map(\.currencies.count).reduce(0, +)
    self.openingId = rng.nextUUID()
    self.openingBalanceIds = (0..<keyCount).map { _ in rng.nextUUID() }
    self.sheetId = rng.nextUUID()
    self.sheetBalanceIds = (0..<keyCount).map { _ in rng.nextUUID() }
    self.differenceId = rng.nextUUID()
    self.differencePartId = rng.nextUUID()
    self.loanLineId = rng.nextUUID()
  }

  // MARK: - Writing

  func write() -> SampleDataSet {
    lifeInKazakhstan()
    dollarsOnTheTengeCard()
    // After the spending they cover.
    topUps()
    withdrawals()
    exchange()
    euroPurchase()
    chargeTypedByHand()
    refunds()
    moneyBack()
    goal()
    borrow()

    var set = base
    set.accountGroups = [russia, kazakhstan]
    set.paymentMethods =
      base.paymentMethods.map { account in
        switch account.id {
        case everyday.id: everyday
        case cash.id: cash
        case travel.id: travel
        default: account
        }
      } + [multi, tenge]
    set.categories += [reconcileExpense, reconcileIncome, tripCategory]
    set.people.append(taylor)
    set.places += [market, cafe]
    set.goals.append(tripGoal)
    set.debts.append(familyLoan)
    set.debtEntries += debtEntries
    set.events = (base.events + events).sorted { left, right in
      left.startDate != right.startDate
        ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
    }
    set.links += links
    set.oneOffPayments = [oneOff]
    set.settings = [
      AccountSettings.setupKey: AccountSettings.Setup.done.rawValue,
      AccountSettings.defaultCurrencyKey: CurrencyCode.rub.code,
      AccountSettings.transferFeeCategoryKey: named.fees.id.uuidString,
      PlanningSettings.reconcileExpenseCategoryKey: reconcileExpense.id.uuidString,
      PlanningSettings.reconcileIncomeCategoryKey: reconcileIncome.id.uuidString,
    ]
    set.transfers = transfers.sorted { left, right in
      left.occurredAt != right.occurredAt
        ? left.occurredAt < right.occurredAt : left.id.uuidString < right.id.uuidString
    }
    count(into: &set)
    set.entries = merged(base.entries, added)
    set.expectations = expectations
    return set
  }

  /// The history's operations and the added ones in time order: of one moment, the history's
  /// first, each list in its own order.
  private func merged(
    _ history: [TransactionEntry], _ layer: [TransactionEntry]
  ) -> [TransactionEntry] {
    let all =
      history.enumerated().map { ($0.offset, $0.element) }
      + layer.enumerated().map { (history.count + $0.offset, $0.element) }
    return all.sorted { left, right in
      let (leftIndex, leftEntry) = left
      let (rightIndex, rightEntry) = right
      let leftMoment = leftEntry.transaction.occurredAt
      let rightMoment = rightEntry.transaction.occurredAt
      return leftMoment != rightMoment ? leftMoment < rightMoment : leftIndex < rightIndex
    }.map(\.1)
  }

  // MARK: - Transfers

  /// Rubles sent from the everyday card to the tenge card every month, on the 3rd, for what the
  /// card spent since the last top-up, in round thousands: the bank converts at its own rate, up
  /// to 3 % under the fixed one, and the rubles cover that too. The money on the card follows its
  /// spending instead of piling up.
  private func topUps() {
    let key = BalanceKey(accountId: tenge.id, currency: Self.kzt)
    var since = base.firstDay
    for day in monthly(3) {
      var rng = stream("top-up", on: day)
      let spent = spending(of: key, from: since, to: day)
      since = day
      let needed = Self.money(spent.decimal * Self.kztRate * Decimal(103) / 100, scale: 4)
      let sent = Self.roundedUp(needed, step: 1_000)
      let received = tenge(forRubles: sent, spreadBp: -rng.int(in: 100...300), step: 10_000)
      transfer(
        on: day, from: everyday, .rub, sent, to: tenge, Self.kzt, received,
        note: word("Top-up of the tenge card", "Пополнение карты в тенге"), rng: &rng)
    }
  }

  /// Cash from an ATM on the 5th of every month, for what cash paid since the last time in round
  /// thousands, with the bank's 1 % fee as an expense of its own in «Комиссии».
  private func withdrawals() {
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    var since = base.firstDay
    for day in monthly(5) {
      var rng = stream("withdrawal", on: day)
      let spent = spending(of: key, from: since, to: day)
      since = day
      let amount = max(AmountE4(whole: 2_000), Self.roundedUp(spent, step: 1_000))
      let made = transfer(
        on: day, from: everyday, .rub, amount, to: cash, .rub, amount,
        note: word("Cash withdrawal", "Снятие наличных"), rng: &rng)
      let fee = AmountE4(raw: amount.raw / 100)
      var part = LayerPart(named.fees, fee)
      part.bySystem = true
      let entry = emit(
        .expense, at: made.occurredAt, parts: [part],
        note: word("Withdrawal fee", "Комиссия за снятие"), account: everyday,
        externalId: OperationLink.transferFee(made.id).externalId, rng: &rng)
      spend(entry)
    }
  }

  /// The money paid from `key` from the start of `from` to the start of `to`, as the layer knows
  /// the history: what left it, whatever came in.
  private func spending(of key: BalanceKey, from: DateOnly, to: DateOnly) -> AmountE4 {
    let start = calendar.startOfDay(from)
    let end = calendar.startOfDay(to)
    var spent = AmountE4.zero
    for entry in base.entries + added {
      guard let move = movement(of: entry), move.key == key, move.at >= start, move.at < end,
        move.amount.raw < 0
      else { continue }
      spent = spent - move.amount
    }
    return spent
  }

  /// Rubles changed into tenge inside the multi-currency account.
  private func exchange() {
    guard let day = offset(4) else { return }
    var rng = stream("exchange", on: day)
    let sent = AmountE4(whole: Int64(rng.int(in: 8...12)) * 1_000)
    let received = tenge(forRubles: sent, spreadBp: -rng.int(in: 50...150), step: 10_000)
    transfer(
      on: day, from: multi, .rub, sent, to: multi, Self.kzt, received,
      note: word("Currency exchange", "Обмен валюты"), rng: &rng)
  }

  @discardableResult
  private func transfer(
    on day: DateOnly, from source: PaymentMethod, _ fromCurrency: CurrencyCode,
    _ sent: AmountE4, to target: PaymentMethod, _ toCurrency: CurrencyCode,
    _ received: AmountE4, note: String, rng: inout SeededRandom
  ) -> Transfer {
    let id = rng.nextUUID()
    let moment = self.moment(on: day, rng: &rng)
    let made = Transfer(
      id: id, occurredAt: moment, fromAccountId: source.id, fromCurrency: fromCurrency,
      fromAmountE4: sent, toAccountId: target.id, toCurrency: toCurrency, toAmountE4: received,
      note: note, createdAt: moment, updatedAt: moment)
    transfers.append(made)
    return made
  }

  // MARK: - Spending in Kazakhstan

  /// Groceries and coffee on the tenge card and a taxi from the tenge of the multi-currency
  /// account, every month: the money of a group out of the summary, spending like any other.
  private func lifeInKazakhstan() {
    for day in monthly(8) {
      var rng = stream("groceries in tenge", on: day)
      let amount = AmountE4(whole: Int64(rng.int(in: 400...1_200)) * 10)
      spend(
        emit(
          .expense, on: day, currency: Self.kzt, rate: Self.kztRate,
          parts: [LayerPart(named.groceries, amount)], place: market, account: tenge, rng: &rng))
    }
    for day in monthly(18) {
      var rng = stream("coffee in tenge", on: day)
      let amount = AmountE4(whole: Int64(rng.int(in: 120...250)) * 10)
      spend(
        emit(
          .expense, on: day, currency: Self.kzt, rate: Self.kztRate,
          parts: [LayerPart(named.coffee, amount)], place: cafe, account: tenge, rng: &rng))
    }
    for day in monthly(26) {
      var rng = stream("taxi in tenge", on: day)
      let amount = AmountE4(whole: Int64(rng.int(in: 150...350)) * 10)
      spend(
        emit(
          .expense, on: day, currency: Self.kzt, rate: Self.kztRate,
          parts: [LayerPart(named.taxi, amount)], account: multi, rng: &rng))
    }
  }

  /// A purchase in euros from the account that holds euros.
  private func euroPurchase() {
    guard let day = offset(8) else { return }
    var rng = stream("euros", on: day)
    let amount = AmountE4(raw: Int64(rng.int(in: 3_000...9_000)) * 100)
    spend(
      emit(
        .expense, on: day, currency: .eur, rate: Self.eurRate,
        parts: [LayerPart(named.clothing, amount)],
        note: word("Online store", "Интернет-магазин"), account: multi, rng: &rng))
  }

  /// Dollars paid with the tenge card, which does not hold them: the card was charged tenge,
  /// at the fixed rates through rubles and the bank's markup of up to 2 %.
  private func dollarsOnTheTengeCard() {
    guard let day = offset(10) else { return }
    var rng = stream("dollars on the tenge card", on: day)
    let amount = AmountE4(raw: Int64(rng.int(in: 500...2_000)) * 100)
    let rubles = Self.money(amount.decimal * Self.usdRate, scale: 4)
    let charged = tenge(forRubles: rubles, spreadBp: rng.int(in: 0...200), step: 100)
    spend(
      emit(
        .expense, on: day, currency: .usd, rate: Self.usdRate,
        parts: [LayerPart(named.hosting, amount)], note: word("VPS hosting", "Хостинг сервера"),
        account: tenge, leg: (Self.kzt, charged), rng: &rng))
  }

  /// Dollars paid with the everyday card, and the rubles the bank charged typed by hand from the
  /// statement, 3 % above the fixed rate: the charge is the operation's rubles, and its rate is
  /// the one the charge implies.
  private func chargeTypedByHand() {
    guard let day = offset(12) else { return }
    var rng = stream("charge typed by hand", on: day)
    let amount = AmountE4(raw: Int64(rng.int(in: 1_500...4_000)) * 100)
    let charged = Self.money(amount.decimal * Self.usdRate * Decimal(103) / 100, scale: 2)
    let rate = DecimalMath.round(charged.decimal / amount.decimal, scale: 6)
    var part = LayerPart(named.electronics, amount)
    part.rubles = charged
    spend(
      emit(
        .expense, on: day, currency: .usd, rate: rate, parts: [part],
        note: word("Phone case", "Чехол для телефона"), account: everyday,
        leg: (.rub, charged), rng: &rng))
  }

  // MARK: - Refunds of a purchase

  /// A purchase refunded whole; one of two parts of another refunded in part; and one refunded
  /// in the next month, which still makes the month of the purchase cheaper.
  private func refunds() {
    if let bought = offset(14), let returned = offset(19) {
      var rng = stream("headphones", on: bought)
      let amount = AmountE4(whole: Int64(rng.int(in: 50...90)) * 100)
      let purchase = emit(
        .expense, on: bought, parts: [LayerPart(named.electronics, amount)],
        note: word("Headphones", "Наушники"), account: everyday, rng: &rng)
      spend(purchase)
      refund(
        purchase.parts[0], of: purchase, amount: amount, on: returned,
        note: word("Headphones returned", "Возврат наушников"), key: "headphones")
    }
    if let bought = offset(15), let returned = offset(21) {
      var rng = stream("clothes", on: bought)
      var jacket = LayerPart(named.clothing, AmountE4(whole: Int64(rng.int(in: 40...80)) * 100))
      jacket.note = word("Jacket", "Куртка")
      var shoes = LayerPart(named.clothing, AmountE4(whole: Int64(rng.int(in: 30...60)) * 100))
      shoes.note = word("Shoes", "Ботинки")
      let purchase = emit(
        .expense, on: bought, parts: [jacket, shoes], note: word("Clothes", "Одежда"),
        account: everyday, rng: &rng)
      spend(purchase)
      let back = AmountE4(whole: shoes.amount.raw / AmountE4.unitsPerWhole * 3 / 10 / 10 * 10)
      refund(
        purchase.parts[1], of: purchase, amount: back, on: returned,
        note: word("Part of the shoes back", "Часть денег за ботинки"), key: "clothes")
    }
    let firstMonth = calendar.daysInMonth(base.firstDay.monthKey)
    if let bought = offset(firstMonth - 2), let returned = offset(firstMonth + 3) {
      var rng = stream("kettle", on: bought)
      let amount = AmountE4(whole: Int64(rng.int(in: 15...40)) * 100)
      let purchase = emit(
        .expense, on: bought, parts: [LayerPart(named.household, amount)],
        note: word("Kettle", "Чайник"), account: everyday, rng: &rng)
      spend(purchase)
      refund(
        purchase.parts[0], of: purchase, amount: amount, on: returned,
        note: word("Kettle returned", "Возврат чайника"), key: "kettle")
    }
  }

  /// A refund of `amount` of `part`, the way the refund sheet writes one: in the purchase's
  /// currency at its rate, onto its account, with the part's category, quality and people. It
  /// makes the purchase's month cheaper by its share of the part's rubles.
  private func refund(
    _ part: TransactionPart, of purchase: TransactionEntry, amount: AmountE4, on day: DateOnly,
    note: String, key: String
  ) {
    var rng = stream("\(key) returned", on: day)
    let whole = amount == part.amountE4
    let rubles =
      whole
      ? part.amountRubE4
      : Self.money(amount.decimal * part.amountRubE4.decimal / part.amountE4.decimal, scale: 4)
    var taken = LayerPart(part.categoryId.flatMap { categoriesById[$0] }, amount)
    taken.rubles = rubles
    taken.refundOf = part
    let transaction = purchase.transaction
    guard let account = accountsById[transaction.paymentMethodId ?? everyday.id] else { return }
    emit(
      .refund, on: day, currency: transaction.currency, rate: transaction.rate,
      parts: [taken], note: note, placeId: transaction.placeId, account: account, rng: &rng)
    let category = part.categoryId.flatMap { categoriesById[$0] }
    expectations.spend(
      -rubles, in: calendar.day(of: transaction.occurredAt).monthKey,
      root: category.map { $0.parentId ?? $0.id }, quality: part.quality ?? .neutral)
  }

  // MARK: - Money back

  /// Taylor owes half of a dinner abroad in dollars and gives back exactly those dollars at
  /// another rate: the part closes whole, and the rubles of the rates' drift are neither income
  /// nor spending. Then half of a dinner in rubles, of which Taylor gives back 40 %: the part
  /// stays owed with the rest, and nothing is a shortfall.
  private func moneyBack() {
    if let dined = offset(22), let paid = offset(27) {
      var rng = stream("dinner abroad", on: dined)
      let total = AmountE4(raw: Int64(rng.int(in: 3_000...6_000)) * 2 * 100)
      let halves = total.split(into: 2)
      let mine = LayerPart(named.restaurants, halves[0])
      var theirs = LayerPart(named.restaurants, halves[1])
      theirs.forWhom = .friends
      theirs.owedBy = taylor.id
      theirs.status = .returned
      let dinner = emit(
        .expense, on: dined, currency: .usd, rate: Self.usdRate, parts: [mine, theirs],
        note: word("Dinner abroad", "Ужин в поездке"), account: travel, rng: &rng)
      spend(dinner)
      let part = dinner.parts[1]
      var back = LayerPart(nil, part.amountE4)
      back.forPersonId = taylor.id
      back.rubles = Self.money(part.amountE4.decimal * Self.moneyBackUsdRate, scale: 4)
      var backRng = stream("dinner abroad paid back", on: paid)
      let money = emit(
        .reimbursement, on: paid, currency: .usd, rate: Self.moneyBackUsdRate, parts: [back],
        account: travel, rng: &backRng)
      links.append(
        ReimbursementLink(
          id: backRng.nextUUID(), reimbursementTxId: money.id, partId: part.id,
          amountE4: part.amountRubE4))
      expectations.settle(
        returned: part.amountRubE4, shortfall: .zero,
        purchasedIn: calendar.day(of: dinner.transaction.occurredAt).monthKey)
    }
    if let dined = offset(30), let paid = offset(35) {
      var rng = stream("dinner", on: dined)
      let total = AmountE4(whole: Int64(rng.int(in: 240...480)) * 10)
      let halves = total.split(into: 2)
      let mine = LayerPart(named.restaurants, halves[0])
      var theirs = LayerPart(named.restaurants, halves[1])
      theirs.forWhom = .friends
      theirs.owedBy = taylor.id
      theirs.status = .expected
      let dinner = emit(
        .expense, on: dined, parts: [mine, theirs],
        note: word("Dinner with Taylor", "Ужин с Taylor"), account: everyday, rng: &rng)
      spend(dinner)
      let part = dinner.parts[1]
      let returned = AmountE4(raw: part.amountRubE4.raw * 4 / 10)
      var back = LayerPart(nil, returned)
      back.forPersonId = taylor.id
      var backRng = stream("dinner paid back", on: paid)
      let money = emit(.reimbursement, on: paid, parts: [back], account: everyday, rng: &backRng)
      links.append(
        ReimbursementLink(
          id: backRng.nextUUID(), reimbursementTxId: money.id, partId: part.id,
          amountE4: returned))
      expectations.settlePartly(
        returned: returned, purchasedIn: calendar.day(of: dinner.transaction.occurredAt).monthKey)
    }
  }

  // MARK: - A goal in dollars

  /// Dollars put into the trip every month from the multi-currency account, and rubles once
  /// from the everyday card. Money put into a goal stays on the account: it moves no balance.
  ///
  /// The trip costs more than the history can put aside — at most 200 dollars a month and the
  /// rubles once, worth less than a hundred — so on the last day of any history the goal is on
  /// its way, never filled over.
  private func goal() {
    let days = monthly(12)
    let most = AmountE4(whole: Int64(days.count) * 200 + 100)
    tripGoal.targetE4 = max(tripGoal.targetE4, Self.roundedUp(most, step: 500))
    for day in days {
      var rng = stream("trip fund", on: day)
      let amount = AmountE4(whole: Int64(rng.int(in: 100...200)))
      spend(
        emit(
          .expense, on: day, currency: .usd, rate: Self.usdRate, parts: [goalPart(amount)],
          note: tripGoal.name, account: multi, rng: &rng))
    }
    guard let day = offset(16) else { return }
    var rng = stream("trip fund in rubles", on: day)
    spend(
      emit(
        .expense, on: day, parts: [goalPart(AmountE4(whole: 5_000))], note: tripGoal.name,
        account: everyday, rng: &rng))
  }

  private func goalPart(_ amount: AmountE4) -> LayerPart {
    var part = LayerPart(tripCategory, amount)
    part.goalId = tripGoal.id
    return part
  }

  // MARK: - Money borrowed through the journal

  /// Money borrowed from the family, put into cash: a line of the debt's journal with its
  /// account and its moment, and no operation.
  private func borrow() {
    guard let day = offset(24) else { return }
    var rng = stream("family loan", on: day)
    debtEntries.append(
      DebtEntry(
        id: loanLineId, debtId: familyLoan.id, date: day, description: familyLoan.name,
        amountE4: AmountE4(whole: 30_000), kind: .borrowed, paymentMethodId: cash.id,
        occurredAt: moment(on: day, rng: &rng)))
  }

  // MARK: - Counts

  /// The opening count of every account and currency on the first day, and the sheet two weeks
  /// before the last day that finds 350 ₽ less cash than expected and writes the difference —
  /// with the money of each key at the end kept in `accountExpectations`.
  ///
  /// An opening balance is whatever keeps the key above zero all along: its lowest point after
  /// the opening, plus a margin, and never below a round amount of its currency.
  private func count(into set: inout SampleDataSet) {
    let keys = Self.keys(of: set.paymentMethods)
    let openingAt = calendar.startOfDay(base.firstDay).addingTimeInterval(1)
    let sheetDay = calendar.adding(days: -14, to: base.lastDay)
    let sheetAt: Date? =
      span >= 30 ? calendar.startOfDay(sheetDay).addingTimeInterval(23 * 3_600 + 30 * 60) : nil
    let cashRubles = BalanceKey(accountId: cash.id, currency: .rub)

    let real = movements(after: openingAt)
    // The cash found short at the sheet is gone from then on: the balances after it start
    // from what was counted.
    var moves = real
    if let sheetAt { moves[cashRubles, default: []].append((sheetAt, Self.cashShort)) }

    var opening: [BalanceKey: AmountE4] = [:]
    for key in keys {
      var lowest = AmountE4.zero
      var running = AmountE4.zero
      for (_, amount) in Self.byMoment(moves[key] ?? []) {
        running += amount
        lowest = min(lowest, running)
      }
      let rule = Self.openingRule(key.currency)
      opening[key] = Self.roundedUp(max(rule.nominal, rule.margin - lowest), step: rule.step)
    }

    // The starting balances are the setup of the accounts, and the sheet records its
    // difference: neither draws from the random stream, so the history stays the same.
    let openingCount = Reconciliation(
      id: openingId, date: base.firstDay, reconciledAt: openingAt, actualTotalRubE4: .zero,
      kind: .opening, origin: .setup)
    set.reconciliations = [openingCount]
    set.reconciledBalances = zip(keys, openingBalanceIds).map { key, id in
      ReconciledBalance(
        id: id, reconciliationId: openingId, accountId: key.accountId, currency: key.currency,
        actualE4: opening[key] ?? .zero)
    }

    var closing: [BalanceKey: AmountE4] = [:]
    for key in Set(keys).union(moves.keys) {
      closing[key] = (opening[key] ?? .zero) + AmountE4.sum((moves[key] ?? []).map(\.amount))
    }
    set.accountExpectations = closing

    guard let sheetAt else { return }
    let sheet = Reconciliation(
      id: sheetId, date: sheetDay, reconciledAt: sheetAt, actualTotalRubE4: .zero,
      kind: .accounts)
    set.reconciliations.append(sheet)
    for (key, id) in zip(keys, sheetBalanceIds) {
      let before = (real[key] ?? []).filter { $0.at <= sheetAt }.map(\.amount)
      let expected = (opening[key] ?? .zero) + AmountE4.sum(before)
      let short = key == cashRubles
      set.reconciledBalances.append(
        ReconciledBalance(
          id: id, reconciliationId: sheetId, accountId: key.accountId, currency: key.currency,
          actualE4: short ? expected + Self.cashShort : expected, expectedE4: expected,
          differenceE4: short ? Self.cashShort : .zero, transactionId: short ? differenceId : nil,
          recordsDifference: true))
      guard short else { continue }
      // The difference, the way the reconciliation sheet records it: an expense in «Сверка»
      // on the account that was short, a line of the books that moves no money.
      let transaction = Transaction(
        id: differenceId, kind: .expense, occurredAt: sheetAt, amountE4: -Self.cashShort,
        amountRubE4: -Self.cashShort, paymentMethodId: cash.id,
        externalId: OperationLink.reconciledBalance(reconciliation: sheetId, balance: id)
          .externalId,
        createdAt: sheetAt, updatedAt: sheetAt)
      let part = TransactionPart(
        id: differencePartId, transactionId: differenceId, categoryId: reconcileExpense.id,
        categorySource: .system, quality: .neutral, qualitySource: .category,
        amountE4: -Self.cashShort, amountRubE4: -Self.cashShort)
      added.append(TransactionEntry(transaction: transaction, parts: [part]))
      expectations.spend(
        -Self.cashShort, in: sheetDay.monthKey, root: reconcileExpense.id, quality: .neutral)
    }
  }

  /// Every movement of money on every key after `start`, as the layer knows the history: an
  /// operation moves its account — by what the account was charged when it does not hold the
  /// currency — down for a purchase and up for anything else; not when it was deleted, not a
  /// line of the books (money back's surplus and shortfall, a difference), not a purchase on
  /// credit, not money put into a goal. A transfer moves both of its ends. Of the journals,
  /// only the money borrowed here moves an account: the bank loan was taken long before the
  /// history, and the phone's debt came with the phone.
  private func movements(after start: Date) -> [BalanceKey: [(at: Date, amount: AmountE4)]] {
    var moves: [BalanceKey: [(at: Date, amount: AmountE4)]] = [:]
    func add(_ key: BalanceKey, _ at: Date, _ amount: AmountE4) {
      guard at > start else { return }
      moves[key, default: []].append((at, amount))
    }
    for entry in base.entries + added {
      guard let move = movement(of: entry) else { continue }
      add(move.key, move.at, move.amount)
    }
    for made in transfers {
      add(made.from, made.occurredAt, -made.fromAmountE4)
      add(made.to, made.occurredAt, made.toAmountE4)
    }
    for line in debtEntries {
      guard let accountId = line.paymentMethodId, let at = line.occurredAt else { continue }
      add(BalanceKey(accountId: accountId, currency: familyLoan.currency), at, line.amountE4)
    }
    return moves
  }

  /// How one operation moves the money of its account, by the rules of `movements(after:)`;
  /// nil when it moves none.
  private func movement(
    of entry: TransactionEntry
  ) -> (key: BalanceKey, at: Date, amount: AmountE4)? {
    let transaction = entry.transaction
    guard transaction.deletedAt == nil, let accountId = transaction.paymentMethodId else {
      return nil
    }
    if let key = transaction.externalId, key.hasPrefix("reimb:") || key.hasPrefix("reconcile:") {
      return nil
    }
    if transaction.kind == .expense, transaction.creditDebtId != nil { return nil }
    if !entry.parts.isEmpty, entry.parts.allSatisfy({ $0.goalId != nil }) { return nil }
    let currency = transaction.accountCurrency ?? transaction.currency
    let amount = transaction.accountAmountE4 ?? transaction.amountE4
    return (
      BalanceKey(accountId: accountId, currency: currency), transaction.occurredAt,
      transaction.kind == .expense ? -amount : amount
    )
  }

  // MARK: - Writing one operation

  /// One part as the layer means it. The category's quality is stored, as the ↓ panel stores
  /// it; a goal's part is good by the app's rule; a refund's copies the part it takes back.
  struct LayerPart {
    var category: CoreKit.Category?
    var amount: AmountE4
    /// The rubles, when they are not the amount at the operation's rate.
    var rubles: AmountE4?
    var note: String?
    var forWhom = ForWhom.me
    var forPersonId: UUID?
    var owedBy: UUID?
    var status: ReimbursementStatus?
    var goalId: UUID?
    var refundOf: TransactionPart?
    /// The app chose the category by a rule of its own (a fee), not the owner.
    var bySystem = false

    init(_ category: CoreKit.Category?, _ amount: AmountE4) {
      self.category = category
      self.amount = amount
    }
  }

  @discardableResult
  private func emit(
    _ kind: TransactionKind, on day: DateOnly? = nil, at given: Date? = nil,
    currency: CurrencyCode = .rub, rate: Decimal? = nil, parts specs: [LayerPart],
    note: String? = nil, place: Place? = nil, placeId: UUID? = nil, account: PaymentMethod,
    leg: (currency: CurrencyCode, amount: AmountE4)? = nil, externalId: String? = nil,
    rng: inout SeededRandom
  ) -> TransactionEntry {
    let id = rng.nextUUID()
    let occurredAt = given ?? moment(on: day ?? base.firstDay, rng: &rng)
    var parts: [TransactionPart] = []
    for spec in specs {
      let rubles =
        spec.rubles ?? rate.map { Self.money(spec.amount.decimal * $0, scale: 4) } ?? spec.amount
      var quality: Quality?
      var qualitySource: QualitySource?
      if kind == .expense || kind == .refund {
        if let taken = spec.refundOf {
          quality = taken.quality
          qualitySource = taken.qualitySource
        } else if spec.goalId != nil {
          quality = .good
          qualitySource = .system
        } else {
          quality = spec.category.map(ruleQuality) ?? .neutral
          qualitySource = .category
        }
      }
      let taken = spec.refundOf
      parts.append(
        TransactionPart(
          id: rng.nextUUID(), transactionId: id, categoryId: spec.category?.id,
          categorySource: spec.bySystem ? .system : .manual, quality: quality,
          qualitySource: qualitySource, amountE4: spec.amount, amountRubE4: rubles,
          forWhom: taken?.forWhom ?? spec.forWhom,
          forPersonId: taken?.forPersonId ?? spec.forPersonId,
          reimbursable: spec.owedBy != nil, debtorPersonId: spec.owedBy,
          reimbursementStatus: spec.owedBy == nil ? nil : (spec.status ?? .expected),
          eventId: taken?.eventId, goalId: spec.goalId, note: spec.note,
          refundOfPartId: taken?.id))
    }
    let day = calendar.day(of: occurredAt)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: occurredAt, currency: currency,
        amountE4: AmountE4.sum(parts.map(\.amountE4)), rate: rate,
        rateDate: rate == nil ? nil : day, rateSource: rate == nil ? nil : .manual,
        amountRubE4: AmountE4.sum(parts.map(\.amountRubE4)), note: note,
        placeId: place?.id ?? placeId, paymentMethodId: account.id,
        accountCurrency: leg?.currency, accountAmountE4: leg?.amount, externalId: externalId,
        createdAt: occurredAt, updatedAt: occurredAt),
      parts: parts)
    added.append(entry)
    return entry
  }

  /// Adds a purchase to the known answers: my spending, but a part paid for somebody else is
  /// theirs until it comes back.
  private func spend(_ entry: TransactionEntry) {
    let month = calendar.day(of: entry.transaction.occurredAt).monthKey
    for part in entry.parts {
      let category = part.categoryId.flatMap { categoriesById[$0] }
      if part.reimbursable, let status = part.reimbursementStatus {
        expectations.payForOthers(part.amountRubE4, in: month, status: status)
        continue
      }
      expectations.spend(
        part.amountRubE4, in: month, root: category.map { $0.parentId ?? $0.id },
        quality: part.quality ?? .neutral)
    }
  }

  /// The quality the rules give a part of this category: its own, else its parent's, else
  /// neutral.
  private func ruleQuality(_ category: CoreKit.Category) -> Quality {
    if let quality = category.quality { return quality }
    return category.parentId.flatMap { categoriesById[$0]?.quality } ?? .neutral
  }

  // MARK: - Days and moments

  /// The day `offset` days after the first day, while it is before the last day.
  private func offset(_ offset: Int) -> DateOnly? {
    guard offset >= 0, offset < span else { return nil }
    return calendar.adding(days: offset, to: base.firstDay)
  }

  /// `day` of every month of the history, before its last day.
  private func monthly(_ day: Int) -> [DateOnly] {
    var days: [DateOnly] = []
    var month = base.firstDay.monthKey
    while month <= base.lastDay.monthKey {
      let date = DateOnly(year: month.year, month: month.month, day: day)
      if date >= base.firstDay, date < base.lastDay { days.append(date) }
      month = month.next
    }
    return days
  }

  /// A random stream for one row of the layer, keyed by what the row is — its feature and its
  /// day — and not by how many rows were drawn before it. Its ids, money and moment are the same
  /// in every history that has that day, whatever its length and last day, so a sample written
  /// again over an earlier one replaces the rows they share, and never turns one of them into
  /// another with other parts.
  private func stream(_ feature: String, on day: DateOnly) -> SeededRandom {
    SeededRandom(seed: layerSeed ^ Self.fnv1a("\(feature)|\(day.iso)"))
  }

  /// FNV-1a over the UTF-8 bytes: the same number on every platform and in every run, which
  /// `Hasher` is not.
  static func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return hash
  }

  /// A time of day between 09:00 and 21:59, never after `now`.
  private func moment(on day: DateOnly, rng: inout SeededRandom) -> Date {
    let seconds = rng.int(in: 9...21) * 3_600 + rng.int(in: 0...59) * 60
    let drawn = calendar.startOfDay(day).addingTimeInterval(TimeInterval(seconds))
    guard let now else { return drawn }
    return min(drawn, now)
  }

  private var accountsById: [UUID: PaymentMethod] {
    Dictionary(
      ([everyday, cash, travel, multi, tenge] + base.paymentMethods).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
  }

  private func word(_ english: String, _ russianText: String) -> String {
    russian ? russianText : english
  }

  // MARK: - Money

  /// Fixed, approximate rates, never fetched and never real market data: the history's own
  /// for dollars and euros, a round one for tenge, and another one for dollars given back.
  static let kzt = CurrencyCode("KZT")
  static let usdRate = Decimal(95)
  static let eurRate = Decimal(103)
  static let kztRate = Decimal(2) / Decimal(10)
  static let moneyBackUsdRate = Decimal(97)
  /// What the sheet finds missing from the cash.
  static let cashShort = AmountE4(whole: -350)

  /// Tenge for `rubles` at the fixed rate, moved by `spreadBp` hundredths of a percent,
  /// rounded half away from zero to whole `step`s of stored units (a tenge is 10 000, a tiyn
  /// 100).
  private func tenge(forRubles rubles: AmountE4, spreadBp: Int, step: Int64) -> AmountE4 {
    let exact = rubles.decimal / Self.kztRate * Decimal(10_000 + spreadBp) / Decimal(10_000)
    let perWhole = Decimal(AmountE4.unitsPerWhole / step)
    return Self.money(DecimalMath.round(exact * perWhole, scale: 0) / perWhole, scale: 4)
  }

  /// `value` in stored units, rounded half away from zero to `scale` decimals.
  static func money(_ value: Decimal, scale: Int) -> AmountE4 {
    (try? AmountE4(decimal: DecimalMath.round(value, scale: scale))) ?? .zero
  }

  /// `amount` rounded up to whole `step`s of its currency.
  private static func roundedUp(_ amount: AmountE4, step: Int64) -> AmountE4 {
    let unit = step * AmountE4.unitsPerWhole
    let steps = (amount.raw + unit - 1) / unit
    return AmountE4(raw: max(1, steps) * unit)
  }

  /// A round opening balance of a currency, the margin kept above the lowest point, and the
  /// step the balance is rounded up to.
  private static func openingRule(
    _ currency: CurrencyCode
  ) -> (nominal: AmountE4, margin: AmountE4, step: Int64) {
    switch currency {
    case .rub: (AmountE4(whole: 30_000), AmountE4(whole: 5_000), 100)
    case .usd: (AmountE4(whole: 300), AmountE4(whole: 50), 10)
    case .eur: (AmountE4(whole: 200), AmountE4(whole: 50), 10)
    default: (AmountE4(whole: 150_000), AmountE4(whole: 20_000), 1_000)
    }
  }

  /// The movements of one key summed by moment, oldest first: a balance is known between
  /// moments, not inside one.
  private static func byMoment(
    _ moves: [(at: Date, amount: AmountE4)]
  ) -> [(Date, AmountE4)] {
    var sums: [Date: AmountE4] = [:]
    for move in moves { sums[move.at, default: .zero] += move.amount }
    return sums.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }

  /// Every live account × each of its currencies, in the order of `BalanceKey`.
  static func keys(of accounts: [PaymentMethod]) -> [BalanceKey] {
    accounts.filter { !$0.archived }.flatMap { account in
      account.currencies.map { BalanceKey(accountId: account.id, currency: $0) }
    }.sorted()
  }

  // MARK: - Coming events

  /// The next birthday of the history's series after `last`, and the New Year under way or next
  /// that the history holds none of, each with a budget. A history too short for a birthday
  /// starts a series.
  private static func comingEvents(
    after last: DateOnly, in events: [Event], ids: (birthday: UUID, newYear: UUID),
    series: (birthday: UUID, newYear: UUID), names: (birthday: String, newYear: String)
  ) -> [Event] {
    let birthday = events.last { $0.kind == .birthday }
    let date: DateOnly
    if let birthday {
      let this = DateOnly(
        year: last.year, month: birthday.startDate.month, day: birthday.startDate.day)
      let next = DateOnly(
        year: last.year + 1, month: birthday.startDate.month, day: birthday.startDate.day)
      date = this > last ? this : next
    } else {
      date = CalendarContext.utc.adding(days: 40, to: last)
    }
    let newYear = events.last { $0.kind == .newYear }
    // The first that has not ended by the last day and is not the history's: on the 28th and
    // 29th of December this year's is under way and the history holds none of it (its shopping
    // comes on the 30th), so its budget is the one being spent.
    let held = Set(events.filter { $0.kind == .newYear }.map(\.startDate))
    var year = last.month == 1 ? last.year - 1 : last.year
    while DateOnly(year: year + 1, month: 1, day: 1) < last
      || held.contains(DateOnly(year: year, month: 12, day: 28))
    {
      year += 1
    }
    return [
      Event(
        id: ids.birthday, name: birthday?.name ?? names.birthday, kind: .birthday,
        startDate: date, endDate: date, budgetE4: AmountE4(whole: 15_000), recurringYearly: true,
        seriesId: birthday?.seriesId ?? series.birthday),
      Event(
        id: ids.newYear, name: newYear?.name ?? names.newYear, kind: .newYear,
        startDate: DateOnly(year: year, month: 12, day: 28),
        endDate: DateOnly(year: year + 1, month: 1, day: 1), budgetE4: AmountE4(whole: 30_000),
        recurringYearly: true, seriesId: newYear?.seriesId ?? series.newYear),
    ]
  }

  // MARK: - Types

  private struct Named {
    let groceries, coffee, taxi, electronics, clothing, household: CoreKit.Category
    let restaurants, hosting, fees, repairs, goals: CoreKit.Category
  }
}
