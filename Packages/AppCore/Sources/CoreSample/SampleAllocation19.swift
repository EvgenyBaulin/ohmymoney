import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The allocation of income, self-employment and a currency of the owner's own, after the
  /// credit:
  ///
  /// * a goal «Отпуск» and two rules of allocation — 10 % to it and 10 % to the safety cushion;
  /// * self-employment turned on, with the categories of the app — «Заработок → Самозанятость →
  ///   от физлиц (4 %) / от организаций (6 %)» — and «Налоги и сборы → Налог самозанятого», the
  ///   deduction left 4,000 on the first day of the month before the last day's;
  /// * «Дебетовая Т-Банка», opened at zero on that day, where the self-employed income comes: an
  ///   income from individuals in the middle of that month, its tax — at the rate the deduction
  ///   leaves — paid in the last day's month under `npd:<month>`, and an income from
  ///   organisations two days before the last day;
  /// * that last income allocated by the rules — a contribution to the goal and a transfer to the
  ///   cushion account, a second after it, keyed `alloc:<income>:<uuid>` —, while the salaries
  ///   of the history stay to be allocated;
  /// * «Мили» (`MIL`), a currency of the owner's own with three rates typed by hand.
  ///
  /// Every row that moves money is on the new account or on the savings account after its last
  /// count, so the counts still find what they found. The layer draws from streams of its own; a
  /// history shorter than two months gets none of it.
  func withAllocationLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: Self.allocationLayerTag, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    guard Self.days(from: firstDay, to: lastDay, calendar: calendar) >= Self.allocationMinimumDays,
      let main = mainAccount, let work = starter("Work", .income)?.category,
      let goalsRoot = starter("Goals")?.category,
      let incomeDay = layer.daysBeforeEnd(2)
    else { return self }
    let month = lastDay.monthKey.previous
    let opened = month.firstDay
    guard opened > firstDay else { return self }
    var set = self

    // The goal and the rules.
    var goalStream = layer.stream("vacation goal")
    let vacationName = layer.word("Vacation", "Отпуск")
    let vacationCategory = CoreKit.Category(
      id: goalStream.nextUUID(), parentId: goalsRoot.id, kind: .expense, name: vacationName,
      sort: set.categories.filter { $0.parentId == goalsRoot.id }.count)
    let vacation = Goal(
      id: goalStream.nextUUID(), name: vacationName, targetE4: AmountE4(whole: 150_000),
      subcategoryId: vacationCategory.id)
    set.categories.append(vacationCategory)
    set.goals.append(vacation)
    let cushion = set.paymentMethods.first { $0.cushion && !$0.archived }
    set.allocationRules += [
      AllocationRule(
        id: goalStream.nextUUID(), target: .goal(vacation.id), amount: .percent(Self.ruleShare),
        sort: 0),
      AllocationRule(
        id: goalStream.nextUUID(), target: .cushion(cushion?.id), amount: .percent(Self.ruleShare),
        sort: 1),
    ]
    set.settings[AllocationSettings.earningsCategoryKey] = work.id.uuidString

    // Self-employment: the categories the app makes, and the settings.
    var categoryStream = layer.stream("self-employment categories")
    func category(
      _ english: String, _ russian: String, kind: CategoryKind, parent: UUID?,
      tax: IncomeTax? = nil
    ) -> CoreKit.Category {
      let sort = set.categories.filter { $0.parentId == parent && $0.kind == kind }.count
      let made = CoreKit.Category(
        id: categoryStream.nextUUID(), parentId: parent, kind: kind,
        name: layer.word(english, russian), sort: sort, tax: tax)
      set.categories.append(made)
      return made
    }
    let selfEmployed = category("Self-employment", "Самозанятость", kind: .income, parent: work.id)
    let individuals = category(
      "from individuals", "от физлиц", kind: .income, parent: selfEmployed.id,
      tax: IncomeTax(rate: NPDReference.law.individualsRate, npd: true))
    let organizations = category(
      "from organisations", "от организаций", kind: .income, parent: selfEmployed.id,
      tax: IncomeTax(rate: NPDReference.law.organizationsRate, npd: true))
    let taxes = category("Taxes and fees", "Налоги и сборы", kind: .expense, parent: nil)
    let taxCategory = category(
      "Tax of self-employment", "Налог самозанятого", kind: .expense, parent: taxes.id)
    let settings = SelfEmploymentSettings(
      enabled: true, offered: true, deductionLeftE4: Self.deductionLeft, deductionLeftOn: opened,
      taxCategoryId: taxCategory.id)
    for (key, value) in settings.storedValues {
      if let value { set.settings[key] = value }
    }

    // The account the self-employed income comes to.
    let account = set.openTBankAccount(
      layer.word("T-Bank debit card", "Дебетовая Т-Банка"), credit: nil, openedOn: opened,
      main: main, layer: layer, stream: "t-bank debit card")

    // The incomes: from individuals in the middle of the month before, from organisations two
    // days before the last day.
    let firstOn = DateOnly(year: month.year, month: month.month, day: 15)
    var firstStream = layer.stream("self-employed income", on: firstOn)
    let first = set.selfEmployedIncome(
      AmountE4(whole: Int64(firstStream.int(in: 30...50)) * 500), in: individuals,
      at: layer.moment(firstOn, hour: 13, minute: firstStream.int(in: 0...59)), account: account.id,
      note: layer.word("Consulting", "Консультация"), rng: &firstStream, calendar: calendar)
    var lastStream = layer.stream("self-employed income", on: incomeDay)
    let last = set.selfEmployedIncome(
      AmountE4(whole: Int64(lastStream.int(in: 40...60)) * 1_000), in: organizations,
      at: layer.moment(incomeDay, hour: 11, minute: lastStream.int(in: 0...59)),
      account: account.id, note: layer.word("Project for a company", "Проект для компании"),
      rng: &lastStream, calendar: calendar)

    // The tax of the month before, at the rates the deduction leaves, paid in the last day's
    // month — on the 10th, or on the last day when that comes first.
    let incomes = [
      (first, NPDReference.law.individualsRate), (last, NPDReference.law.organizationsRate),
    ]
    var deduction = Self.deductionLeft.decimal
    var monthTax = Decimal(0)
    var monthCut = Decimal(0)
    var lastTax = AmountE4.zero
    for (income, rate) in incomes {
      let amount = income.transaction.amountE4.decimal
      let cut =
        rate == NPDReference.law.individualsRate
        ? NPDReference.law.individualsCut : NPDReference.law.organizationsCut
      let used = min(amount * cut / 100, max(0, deduction))
      deduction -= used
      if calendar.day(of: income.transaction.occurredAt).monthKey == month {
        monthTax += amount * rate / 100
        monthCut += used
      }
      if income.id == last.id { lastTax = InterestMath.cents(amount * rate / 100 - used) }
    }
    let tax = InterestMath.cents(max(0, monthTax - monthCut))
    let paidOn = DateOnly(
      year: lastDay.year, month: lastDay.month, day: min(lastDay.day, Self.taxPaidDay))
    if tax >= NPDReference.law.minimumTaxE4 {
      var rng = layer.stream("self-employed tax", on: paidOn)
      var payment = layer.purchase(
        tax, of: taxCategory, parent: taxes,
        at: layer.moment(paidOn, hour: 10, minute: rng.int(in: 0...59)), account: account.id,
        note: layer.word("Tax of self-employment", "Налог самозанятого"), rng: &rng)
      payment.transaction.externalId = "npd:" + month.iso
      set.add(payment, calendar: calendar)
    }

    // The last income allocated by the rules: the base is the income less its tax.
    let base = last.transaction.amountE4 - lastTax
    let share = InterestMath.cents(base.decimal * Self.ruleShare / 100)
    let at = last.transaction.occurredAt.addingTimeInterval(1)
    var allocationStream = layer.stream("allocation", on: incomeDay)
    let contributionId = allocationStream.nextUUID()
    let contribution = TransactionEntry(
      transaction: Transaction(
        id: contributionId, kind: .expense, occurredAt: at, amountE4: share, amountRubE4: share,
        paymentMethodId: account.id,
        externalId: Self.allocationKey(income: last.id, uuid: allocationStream.nextUUID()),
        createdAt: at, updatedAt: at),
      parts: [
        TransactionPart(
          id: allocationStream.nextUUID(), transactionId: contributionId,
          categoryId: vacationCategory.id, categorySource: .system, quality: .good,
          qualitySource: .system, amountE4: share, amountRubE4: share, goalId: vacation.id)
      ])
    set.add(contribution, calendar: calendar)
    if let cushion {
      set.addTransfer(
        Transfer(
          id: allocationStream.nextUUID(), occurredAt: at, fromAccountId: account.id,
          fromCurrency: .rub, fromAmountE4: share, toAccountId: cushion.id, toCurrency: .rub,
          toAmountE4: share, createdAt: at, updatedAt: at,
          externalId: Self.allocationKey(income: last.id, uuid: allocationStream.nextUUID())))
    }

    // Miles: a currency of the owner's own, with its rates typed by hand.
    set.customCurrencies.append(
      CustomCurrency(
        code: Self.milesCode, name: layer.word("Miles", "Мили"), symbol: "✈",
        fractionDigits: 0))
    for (days, rate) in [(45, "1.1"), (20, "1.15"), (3, "1.2")] {
      guard let day = layer.daysBeforeEnd(days), let value = Decimal(string: rate) else {
        continue
      }
      set.rates.append(
        Rate(date: day, currency: Self.milesCode, rubPerUnit: value, source: .manual))
    }
    return set
  }

  /// «ALLOC_19»: the tag of the allocation layer's streams.
  static let allocationLayerTag: UInt64 = 0x414C_4C4F_435F_3139
  /// The shortest history that gets the layer.
  static let allocationMinimumDays = 60
  /// The share of each rule, in percent.
  static let ruleShare = Decimal(10)
  /// The deduction left on the first day of the layer.
  static let deductionLeft = AmountE4(whole: 4_000)
  /// The day of the month the tax of the month before is paid on.
  static let taxPaidDay = 10
  /// The code of the owner's own currency.
  public static let milesCode = CurrencyCode("MIL")

  /// `alloc:<income>:<uuid>` — the key the app writes the rows of an allocation with.
  static func allocationKey(income: UUID, uuid: UUID) -> String {
    "alloc:\(income.uuidString):\(uuid.uuidString)"
  }

  /// An income of one part in rubles on `account`: of the month of its day, and money come to
  /// the account.
  fileprivate mutating func selfEmployedIncome(
    _ amount: AmountE4, in category: CoreKit.Category, at moment: Date, account: UUID,
    note: String, rng: inout SeededRandom, calendar: CalendarContext
  ) -> TransactionEntry {
    let id = rng.nextUUID()
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .income, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        note: note, paymentMethodId: account, createdAt: moment, updatedAt: moment),
      parts: [
        TransactionPart(
          id: rng.nextUUID(), transactionId: id, categoryId: category.id, amountE4: amount,
          amountRubE4: amount)
      ])
    insertInTime(entry)
    expectations.receive(amount, for: calendar.day(of: moment).monthKey)
    let key = BalanceKey(accountId: account, currency: .rub)
    accountExpectations[key] = (accountExpectations[key] ?? .zero) + amount
    return entry
  }
}
