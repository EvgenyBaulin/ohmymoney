import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Settings → Планирование, «Самозанятость»: the switch, the deduction left, the account of the
/// tax and the reference of the law; each write one step of ⌘Z of only the keys that change.
@MainActor
final class SelfEmploymentSettingsTests: CushionDatabaseTestCase {
  private func stored() -> SelfEmploymentSettings { SelfEmploymentSettingsForm.read(environment) }

  private func write(_ next: SelfEmploymentSettings) throws {
    let change = try XCTUnwrap(
      SelfEmploymentSettingsForm.change(from: stored(), to: next, at: Date()))
    XCTAssertTrue(store.apply(change))
  }

  func testOnlyTheKeysThatChangeAreWritten() throws {
    let before = SelfEmploymentSettings(enabled: true, offered: true)
    var after = before
    after.taxAccountId = UUID()
    let change = try XCTUnwrap(
      SelfEmploymentSettingsForm.change(from: before, to: after, at: Date()))
    XCTAssertEqual(Array(change.settings.keys), [SelfEmploymentSettings.taxAccountKey])
    XCTAssertNil(SelfEmploymentSettingsForm.change(from: before, to: before, at: Date()))
  }

  /// Switched off: nothing counted any more, but what was told stays for the day it is back.
  func testSwitchingOffKeepsWhatWasTold() {
    let told = SelfEmploymentSettings(
      enabled: true, deductionLeftE4: AmountE4(whole: 4_000), taxAccountId: UUID(),
      overrides: NPDOverrides(dueDay: 25))
    let off = SelfEmploymentSettingsForm.disabling(told)
    XCTAssertFalse(off.enabled)
    XCTAssertEqual(off.deductionLeftE4, told.deductionLeftE4)
    XCTAssertEqual(off.taxAccountId, told.taxAccountId)
    XCTAssertEqual(off.overrides, told.overrides)
  }

  /// The values typed into the reference: a percent of 0…100, an amount of zero or more, a year
  /// limit above zero; the law's own value is no correction, an empty field is the law again.
  func testTheReferenceTakesWhatReadsAndTheLawIsNoCorrection() throws {
    let base = SelfEmploymentSettings(enabled: true)
    typealias Form = SelfEmploymentSettingsForm
    XCTAssertEqual(
      Form.setting(.individualsRate, to: "3,5", in: base)?.overrides.individualsRate, 3.5)
    XCTAssertNil(Form.setting(.individualsRate, to: "4", in: base)?.overrides.individualsRate)
    XCTAssertNil(Form.setting(.individualsRate, to: "0", in: base))
    XCTAssertNil(Form.setting(.organizationsRate, to: "120", in: base))
    XCTAssertNil(Form.setting(.organizationsRate, to: "абв", in: base))
    XCTAssertEqual(
      Form.setting(.yearLimit, to: "3,000,000", in: base)?.overrides.yearLimitE4,
      AmountE4(whole: 3_000_000))
    XCTAssertNil(Form.setting(.yearLimit, to: "0", in: base))
    XCTAssertEqual(
      Form.setting(.minimumTax, to: "0", in: base)?.overrides.minimumTaxE4, AmountE4.zero)
    XCTAssertNil(Form.setting(.deduction, to: "-5", in: base))
    var corrected = base
    corrected.overrides.deductionTotalE4 = AmountE4(whole: 12_000)
    XCTAssertNil(Form.setting(.deduction, to: " ", in: corrected)?.overrides.deductionTotalE4)
    XCTAssertNil(Form.setting(dueDay: 28, in: base).overrides.dueDay, "the law's day")
    XCTAssertEqual(Form.setting(dueDay: 40, in: base).overrides.dueDay, 31)
    XCTAssertEqual(Form.setting(remindDays: 5, in: base).overrides.remindDaysBefore, 5)
    XCTAssertEqual(Form.setting(remindDays: -2, in: base).overrides.remindDaysBefore, 0)
  }

  /// «Сколько вычета осталось?» is kept with the day it was told on; an empty field — not told.
  func testTheDeductionLeftIsKeptWithItsDay() throws {
    let today = DateOnly(year: 2026, month: 10, day: 13)
    let told = try XCTUnwrap(
      SelfEmploymentSettingsForm.setting(
        deductionLeft: "6,500", today: today, in: SelfEmploymentSettings(enabled: true)))
    XCTAssertEqual(told.deductionLeftE4, AmountE4(whole: 6_500))
    XCTAssertEqual(told.deductionLeftOn, today)
    let cleared = try XCTUnwrap(
      SelfEmploymentSettingsForm.setting(deductionLeft: "", today: today, in: told))
    XCTAssertNil(cleared.deductionLeftE4)
    XCTAssertNil(cleared.deductionLeftOn)
    XCTAssertNil(
      SelfEmploymentSettingsForm.setting(deductionLeft: "много", today: today, in: told))
  }

  /// Each write lands in the database and is undone by its own ⌘Z.
  func testEachWriteIsOneStepOfUndo() throws {
    let account = try account("Налоговый")
    try write(SelfEmploymentSettings(enabled: true, offered: true))
    var next = stored()
    next.taxAccountId = account.id
    try write(next)
    next = try XCTUnwrap(
      SelfEmploymentSettingsForm.setting(.individualsRate, to: "3", in: stored()))
    try write(next)
    XCTAssertEqual(stored().reference.individualsRate, 3)
    XCTAssertEqual(stored().taxAccountId, account.id)

    store.undo()
    XCTAssertEqual(stored().reference.individualsRate, 4, "the correction was not undone")
    XCTAssertEqual(stored().taxAccountId, account.id)
    try write(SelfEmploymentSettingsForm.disabling(stored()))
    XCTAssertFalse(stored().enabled)
    store.undo()
    XCTAssertTrue(stored().enabled)
    store.undo()
    XCTAssertNil(stored().taxAccountId)
  }

  /// The words of the section, in both languages, none shown as a raw key.
  func testTheWordsInBothLanguages() {
    let keys =
      [
        "settings.selfEmployed", "settings.selfEmployed.enabled",
        "settings.selfEmployed.enabledHint", "settings.selfEmployed.deductionLeft",
        "settings.selfEmployed.deductionLeft.hint", "settings.selfEmployed.taxAccount",
        "settings.selfEmployed.taxAccountHint", "settings.selfEmployed.taxAccount.none",
        "settings.selfEmployed.refusal.amount", "settings.selfEmployed.refusal.percent",
        "settings.selfEmployed.reference", "settings.selfEmployed.referenceHint",
        "settings.selfEmployed.referenceReset", "settings.allocation", "settings.allocation.rules",
        "settings.allocation.rules.open", "settings.allocation.rules.none",
        "settings.allocation.hint", "settings.hints", "settings.hints.burnout",
        "settings.hints.burnoutHint", "settings.hints.burnoutNeedsEssentials",
        "settings.hints.creditHistory", "settings.hints.creditHistoryHint",
      ] + SelfEmploymentSettingsForm.ReferenceField.allCases.map(\.titleKey)
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
      let days = environment.format(
        "settings.selfEmployed.reference.remindDays", table: "Settings", counts: 3)
      XCTAssertTrue(days.contains("3"), days)
      XCTAssertFalse(days.contains("%"), days)
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("settings.selfEmployed.enabled", table: "Settings"), "Я самозанятый")
    XCTAssertEqual(
      environment.format(
        "settings.selfEmployed.reference.remindDays", table: "Settings", counts: 5),
      "Напомнить за 5 дней")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.language("settings.selfEmployed.enabled", table: "Settings"), "I'm self-employed")
    environment.language.choice = .system
  }

  /// «Правил: 3 · включено: 2», or «Правил нет».
  func testTheCaptionOfTheRules() {
    environment.language.choice = .russian
    let goal = AllocationRule(target: .cushion(nil), amount: .percent(10), sort: 0)
    var off = AllocationRule(target: .account(UUID()), amount: .percent(5), sort: 1)
    off.active = false
    XCTAssertEqual(AllocationSettingsSection.caption(rules: [], environment), "Правил нет")
    XCTAssertEqual(
      AllocationSettingsSection.caption(rules: [goal, off], environment),
      "Правил: 2 · включено: 1")
    environment.language.choice = .english
    XCTAssertEqual(
      AllocationSettingsSection.caption(rules: [goal, off], environment), "Rules: 2 · on: 1")
    environment.language.choice = .system
  }

  /// The two hints are on until switched off; the burnout hint needs a category marked
  /// essential, a system one or one in the archive does not count.
  func testTheHintsAreOnUntilSwitchedOffAndBurnoutNeedsEssentials() throws {
    // The switches write the very keys «Стоит посмотреть» and the reminders read.
    XCTAssertEqual(PlanningHintSettings.burnoutEnabledKey, "insights.burnout.enabled")
    XCTAssertEqual(PlanningHintSettings.burnoutEnabledKey, BurnoutShowing.enabledKey)
    XCTAssertEqual(
      PlanningHintSettings.creditHistoryEnabledKey, DebtReminderMarks.creditHistoryEnabledKey)
    XCTAssertEqual(PlanningHintSettings.creditHistoryEnabledKey, "reminders.creditHistory.enabled")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ohmymoney-hints-\(UUID().uuidString)"))
    XCTAssertTrue(PlanningHintSettings.isOn(PlanningHintSettings.burnoutEnabledKey, in: defaults))
    defaults.set(false, forKey: PlanningHintSettings.creditHistoryEnabledKey)
    XCTAssertFalse(
      PlanningHintSettings.isOn(PlanningHintSettings.creditHistoryEnabledKey, in: defaults))

    let food = CoreKit.Category(kind: .expense, name: "Еда")
    let fun = CoreKit.Category(kind: .expense, name: "Развлечения", essential: false)
    var old = CoreKit.Category(kind: .expense, name: "Старое", essential: true)
    old.archived = true
    XCTAssertTrue(PlanningHintSettings.burnoutNeedsEssentials([food, fun, old]))
    let rent = CoreKit.Category(kind: .expense, name: "Аренда", essential: true)
    let flat = CoreKit.Category(parentId: rent.id, kind: .expense, name: "Квартира")
    XCTAssertFalse(PlanningHintSettings.burnoutNeedsEssentials([food, rent, flat]))
  }
}

/// Settings → Категории, «Налог» of an income category while the owner is self-employed: none,
/// the two rates of the tax on professional income, another rate, or the category's own for a
/// subcategory; a choice is one step of ⌘Z. The category the tax is paid in takes no limit.
@MainActor
final class CategoryTaxMenuTests: CushionDatabaseTestCase {
  func testTheChoicesAndWhatTheyStore() {
    let top = CoreKit.Category(kind: .income, name: "Заработок")
    let child = CoreKit.Category(parentId: top.id, kind: .income, name: "Фриланс")
    let law = NPDReference.law
    XCTAssertEqual(CategoryTax.choices(for: top, reference: law), [.none, .npd(4), .npd(6)])
    XCTAssertEqual(
      CategoryTax.choices(for: child, reference: law), [.inherit, .none, .npd(4), .npd(6)])
    var corrected = law
    corrected.individualsRate = 5
    XCTAssertEqual(CategoryTax.choices(for: top, reference: corrected), [.none, .npd(5), .npd(6)])

    XCTAssertEqual(CategoryTax.choice(of: top), .none)
    XCTAssertEqual(CategoryTax.choice(of: child), .inherit)
    XCTAssertNil(CategoryTax.value(of: .none, for: top))
    XCTAssertEqual(CategoryTax.value(of: .none, for: child), IncomeTax(rate: 0))
    XCTAssertNil(CategoryTax.value(of: .inherit, for: child))
    XCTAssertEqual(CategoryTax.value(of: .npd(4), for: child), IncomeTax(rate: 4, npd: true))
    XCTAssertEqual(CategoryTax.value(of: .other(13), for: top), IncomeTax(rate: 13))

    var taxed = child
    taxed.tax = IncomeTax(rate: 0)
    XCTAssertEqual(CategoryTax.choice(of: taxed), .none)
    taxed.tax = IncomeTax(rate: 6, npd: true)
    XCTAssertEqual(CategoryTax.choice(of: taxed), .npd(6))
    taxed.tax = IncomeTax(rate: 6)
    XCTAssertEqual(CategoryTax.choice(of: taxed), .other(6))
    XCTAssertNil(CategoryTax.rate("0"))
    XCTAssertEqual(CategoryTax.rate("13"), 13)
  }

  /// An expense category and a system one carry no tax; nothing is written for them.
  func testOnlyTheOwnersIncomeCategoriesCarryATax() {
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    let surplus = CoreKit.Category(kind: .income, name: "Доплаты", systemRole: .surcharges)
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    let tree = CategoryTree([food, surplus, salary])
    XCTAssertTrue(CategoryTax.isFixed(food, in: tree))
    XCTAssertTrue(CategoryTax.isFixed(surplus, in: tree))
    XCTAssertFalse(CategoryTax.isFixed(salary, in: tree))
    XCTAssertNil(CategoryTax.change(food, to: .npd(4), tree: tree, at: Date()))
    XCTAssertNil(CategoryTax.change(salary, to: .none, tree: tree, at: Date()), "already none")
  }

  /// «4 % НПД» on the category, «Нет» on one subcategory, «Как у категории» on the other: the
  /// tree reads it so, and each choice is undone by its own ⌘Z.
  func testAChoiceIsOneStepOfUndoAndTheTreeReadsIt() throws {
    let freelance = try category("Фриланс", kind: .income)
    let clients = try category("Клиенты", parent: freelance.id, kind: .income)
    let gifts = try category("Подарки", parent: freelance.id, kind: .income)
    var tree = CategoryTree(try categories())
    XCTAssertTrue(
      store.apply(
        try XCTUnwrap(CategoryTax.change(freelance, to: .npd(4), tree: tree, at: Date()))))
    tree = CategoryTree(try categories())
    XCTAssertTrue(
      store.apply(
        try XCTUnwrap(
          CategoryTax.change(
            try XCTUnwrap(try stored(gifts.id)), to: .none, tree: tree, at: Date()))))

    tree = CategoryTree(try categories())
    XCTAssertEqual(tree.tax(of: clients.id), IncomeTax(rate: 4, npd: true))
    XCTAssertNil(tree.tax(of: gifts.id), "«Нет» under a taxed category owes nothing")

    store.undo()
    tree = CategoryTree(try categories())
    XCTAssertEqual(tree.tax(of: gifts.id), IncomeTax(rate: 4, npd: true))
    store.undo()
    XCTAssertNil(try stored(freelance.id)?.tax)
  }

  /// The category the tax is paid in and everything under it take no limit.
  func testTheTaxCategoryTakesNoLimit() {
    let taxes = CoreKit.Category(kind: .expense, name: "Налоги и сборы")
    let tax = CoreKit.Category(parentId: taxes.id, kind: .expense, name: "Налог самозанятого")
    let fine = CoreKit.Category(parentId: taxes.id, kind: .expense, name: "Штрафы")
    let tree = CategoryTree([taxes, tax, fine])
    XCTAssertTrue(LimitRules.offersLimit(on: tax.id, tree: tree))
    XCTAssertFalse(LimitRules.offersLimit(on: tax.id, tree: tree, taxCategoryId: tax.id))
    XCTAssertTrue(LimitRules.offersLimit(on: fine.id, tree: tree, taxCategoryId: tax.id))
  }

  /// The words of the menu: «4 % НПД» with a non-breaking space in Russian, «4% NPD» in English.
  func testTheWords() {
    environment.language.choice = .russian
    XCTAssertEqual(CategoryTax.title(.npd(4), environment), "4\u{00A0}% НПД")
    XCTAssertEqual(CategoryTax.title(.other(6), environment), "6\u{00A0}%")
    XCTAssertEqual(CategoryTax.title(.inherit, environment), "Как у категории")
    XCTAssertEqual(CategoryTax.title(.none, environment), "Нет")
    environment.language.choice = .english
    XCTAssertEqual(CategoryTax.title(.npd(4), environment), "4% NPD")
    XCTAssertEqual(CategoryTax.title(.other(13), environment), "13%")
    for key in [
      "categories.tax", "categories.tax.other", "categories.tax.otherRate",
      "categories.tax.otherHint", "settings.write.refused", "accounts.creditTerms",
      "accounts.caption.credit",
    ] {
      for choice in [AppLanguage.Choice.russian, .english] {
        environment.language.choice = choice
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
    environment.language.choice = .system
  }
}

/// Settings → Валюты, «Свои валюты»: a currency outside the bank with its rates typed by hand —
/// written, edited, archived, deleted and reordered, each one step of ⌘Z; an ISO code and the
/// symbol of a currency of the bank are refused before anything is written.
@MainActor
final class CustomCurrencySettingsTests: CushionDatabaseTestCase {
  private let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4)
  private let day = DateOnly(year: 2026, month: 10, day: 1)
  private var actions: CustomCurrencyActions {
    CustomCurrencyActions(environment: environment, store: store)
  }

  private func custom() throws -> [CustomCurrency] {
    try XCTUnwrap(environment.currencies).customCurrencies()
  }

  private func rates(_ code: CurrencyCode) throws -> [Rate] {
    try XCTUnwrap(environment.currencies).rates(of: code)
  }

  func testANewCurrencyWithItsFirstRateIsOneStepOfUndo() throws {
    XCTAssertEqual(actions.save(tether, firstRate: (day, 95.5)), .done)
    XCTAssertEqual(try custom().map(\.code), [tether.code])
    XCTAssertEqual(try rates(tether.code).map(\.rubPerUnit), [95.5])
    XCTAssertTrue(environment.currencyCatalog.isCustom(tether.code), "the catalog was not read")
    store.undo()
    XCTAssertEqual(try custom(), [])
    XCTAssertEqual(try rates(tether.code), [])
  }

  /// An ISO code, the symbol «$», a code of two letters and a lowercase code are refused on the
  /// fly and on the write; nothing is written.
  func testAnISOCodeAndTheSymbolOfTheBankAreRefused() throws {
    func refusal(_ code: String, _ symbol: String = "", name: String = "Монета") -> String? {
      CustomCurrencyEditor.refusal(
        code: code, name: name, symbol: symbol, digits: 2, rateText: "", previous: nil,
        existing: [tether])
    }
    XCTAssertEqual(refusal("USD"), "currencies.custom.refusal.iso")
    XCTAssertEqual(refusal("ZZT", "$"), "currencies.custom.refusal.bankSymbol")
    XCTAssertEqual(refusal("ZZT", "₮"), "currencies.custom.refusal.symbolTaken")
    XCTAssertEqual(refusal("zzt"), "currencies.custom.refusal.code")
    XCTAssertEqual(refusal("ZT"), "currencies.custom.refusal.code")
    XCTAssertEqual(refusal("UST"), "currencies.custom.refusal.taken")
    XCTAssertEqual(refusal("ZZT", name: " "), "currencies.custom.refusal.name")
    XCTAssertEqual(refusal("ZZT", "1z"), "currencies.custom.refusal.symbolNotASign")
    XCTAssertNil(refusal("ZZT", "ⓩ"))
    XCTAssertEqual(
      CustomCurrencyEditor.refusal(
        code: "ZZT", name: "Монета", symbol: "", digits: 2, rateText: "0", previous: nil,
        existing: []),
      "currencies.custom.refusal.rate")

    let usd = CustomCurrency(code: .usd, name: "Доллар")
    XCTAssertEqual(actions.save(usd, firstRate: nil), .refused("currencies.custom.refusal.iso"))
    let dollarSign = CustomCurrency(code: CurrencyCode("ZZT"), name: "Z", symbol: "$")
    XCTAssertEqual(
      actions.save(dollarSign, firstRate: nil), .refused("currencies.custom.refusal.bankSymbol"))
    XCTAssertEqual(try custom(), [])
  }

  /// Rates by day: a rate holds from its day on; one typed again for a day replaces it; one
  /// taken away leaves the earlier one in force; each a step of ⌘Z.
  func testTheRatesHaveAHistory() throws {
    XCTAssertEqual(actions.save(tether, firstRate: (day, 95)), .done)
    let later = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertEqual(actions.saveRate(tether.code, on: later, rubPerUnit: 97), .done)
    let repository = try XCTUnwrap(environment.currencies)
    XCTAssertEqual(
      try repository.rate(of: tether.code, on: DateOnly(year: 2026, month: 10, day: 5))?
        .rubPerUnit, 95)
    XCTAssertEqual(try repository.rate(of: tether.code, on: later)?.rubPerUnit, 97)
    XCTAssertNil(
      try repository.rate(of: tether.code, on: DateOnly(year: 2026, month: 9, day: 30)),
      "a day before the first rate has none")
    XCTAssertEqual(actions.saveRate(tether.code, on: later, rubPerUnit: 98), .done)
    XCTAssertEqual(try rates(tether.code).map(\.rubPerUnit), [98, 95])
    XCTAssertEqual(actions.removeRate(tether.code, on: later), .done)
    XCTAssertEqual(try repository.rate(of: tether.code, on: later)?.rubPerUnit, 95)
    store.undo()
    XCTAssertEqual(try rates(tether.code).map(\.rubPerUnit), [98, 95])
    XCTAssertEqual(
      actions.saveRate(tether.code, on: later, rubPerUnit: 0),
      .refused("currencies.custom.refusal.rate"))
    XCTAssertEqual(
      actions.saveRate(.usd, on: later, rubPerUnit: 90),
      .refused("currencies.custom.refusal.notCustom"))
  }

  /// The archive and back; a currency nothing names is deleted with its rates, one in use — the
  /// default currency — only goes to the archive; ⌘Z brings a deleted one back.
  func testArchiveDeleteAndTheDefaultCurrency() throws {
    XCTAssertEqual(actions.save(tether, firstRate: (day, 95)), .done)
    XCTAssertEqual(actions.archive(tether.code, true), .done)
    XCTAssertEqual(try custom().first?.archived, true)
    XCTAssertFalse(environment.currencyCatalog.active.contains { $0.code == tether.code })
    XCTAssertEqual(actions.archive(tether.code, false), .done)
    XCTAssertEqual(try custom().first?.archived, false)

    XCTAssertEqual(actions.delete(tether.code), .done)
    XCTAssertEqual(try custom(), [])
    XCTAssertEqual(try rates(tether.code), [])
    store.undo()
    XCTAssertEqual(try custom().map(\.code), [tether.code])
    XCTAssertEqual(try rates(tether.code).count, 1)

    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(tether.code, in: environment))
    XCTAssertEqual(actions.delete(tether.code), .refused("currencies.custom.refusal.inUse"))
    XCTAssertEqual(
      actions.archive(tether.code, true), .refused("currencies.custom.refusal.default"))
  }

  /// «Выше» / «Ниже» move a currency one place; the first goes no higher.
  func testTheOrderIsMovedAPlaceAtATime() throws {
    let points = CustomCurrency(code: CurrencyCode("PTS"), name: "Баллы", fractionDigits: 0)
    XCTAssertEqual(actions.save(tether, firstRate: nil), .done)
    XCTAssertEqual(actions.save(points, firstRate: nil), .done)
    XCTAssertEqual(try custom().map(\.code.code), ["UST", "PTS"])
    XCTAssertEqual(actions.move(points.code, by: -1, in: try custom()), .done)
    XCTAssertEqual(try custom().map(\.code.code), ["PTS", "UST"])
    XCTAssertNil(CustomCurrencyActions.moved(points.code, by: -1, in: [points.code, tether.code]))
    store.undo()
    XCTAssertEqual(try custom().map(\.code.code), ["UST", "PTS"])
  }

  /// Every refusal and every word of the section reads in both languages.
  func testTheWordsInBothLanguages() {
    let keys =
      CustomCurrencyText.refusalKeys + [
        "currencies.custom", "currencies.custom.hint", "currencies.custom.empty",
        "currencies.custom.add", "currencies.custom.new", "currencies.custom.edit",
        "currencies.custom.code", "currencies.custom.name", "currencies.custom.symbol",
        "currencies.custom.firstRate", "currencies.custom.rateDay",
        "currencies.custom.firstRateHint", "currencies.custom.rates",
        "currencies.custom.rateOnDay", "currencies.custom.rate", "currencies.custom.rateSave",
        "currencies.custom.ratesHint", "currencies.custom.noRate", "currencies.custom.archived",
        "currencies.custom.moveUp", "currencies.custom.moveDown", "currencies.custom.archive",
        "currencies.custom.restore", "currencies.custom.delete",
      ]
    XCTAssertEqual(Set(CustomCurrencyText.refusalKeys).count, 13, "two refusals share words")
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
      let count = environment.format("settings.currencies.countOn", table: "Settings", counts: 15)
      XCTAssertTrue(count.contains("15"), count)
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.format(
        "currencies.custom.rateFrom", table: "Settings", "UST", "95.5", "1 октября 2026 г."),
      "1 UST = 95.5 ₽ с 1 октября 2026 г.")
    environment.language.choice = .system
  }

  func testTheTitleOfARow() {
    XCTAssertEqual(CustomCurrenciesSection.title(tether), "UST · Tether · ₮")
    XCTAssertEqual(
      CustomCurrenciesSection.title(CustomCurrency(code: CurrencyCode("PTS"), name: "Баллы")),
      "PTS · Баллы")
  }
}

/// The search of the settings finds what 1.9 added, in either language, and the sections that
/// hold it still fit beside the widest sidebar in the smallest window with everything shown.
@MainActor
final class Settings19SearchTests: XCTestCase {
  private let words = SettingsSearch.catalogWords()

  func testTheNewSettingsAreFoundInEitherLanguage() {
    let cases: [(String, SettingsSection, SettingsCaption)] = [
      ("самозанят", .planning, .settings("settings.selfEmployed.enabled")),
      ("self-employ", .planning, .settings("settings.selfEmployed.enabled")),
      ("вычет", .planning, .settings("settings.selfEmployed.deductionLeft")),
      ("справочник налога", .planning, .settings("settings.selfEmployed.reference")),
      ("правила распределения", .planning, .settings("settings.allocation.rules")),
      ("allocation rules", .planning, .settings("settings.allocation.rules")),
      ("выгоран", .planning, .settings("settings.hints.burnout")),
      ("burnout", .planning, .settings("settings.hints.burnout")),
      ("кредитной истории", .planning, .settings("settings.hints.creditHistory")),
      ("свои валюты", .currencies, .settings("currencies.custom")),
      ("own currencies", .currencies, .settings("currencies.custom")),
      ("основная карта", .accounts, .accounts("account.mainCard")),
      ("main card", .accounts, .accounts("account.mainCard")),
      ("условия кредитки", .accounts, .settings("accounts.creditTerms")),
    ]
    for (query, section, caption) in cases {
      let found = SettingsSearch.find(query, words: words)
      let hit = found.first { $0.section == section }
      XCTAssertNotNil(hit, "«\(query)» did not find \(section): \(found)")
      XCTAssertTrue(
        hit?.captions.contains(caption) ?? false, "«\(query)»: \(String(describing: hit))")
    }
    let tax = SettingsSearch.find("Налог", words: words)
    XCTAssertTrue(tax.contains { $0.section == .categories }, "\(tax)")
    XCTAssertTrue(tax.contains { $0.section == .planning }, "\(tax)")
  }

  /// With self-employment on and own currencies listed, the sections still fit in the 590 points
  /// the smallest window leaves beside the widest sidebar, in either language.
  func testTheNewSectionsFitBesideTheSidebar() {
    let room = CGSize(
      width: SettingsView.minimumSize.width - SettingsView.sidebarWidth.max,
      height: SettingsView.minimumSize.height)
    XCTAssertEqual(room.width, 590)
    let selfEmployed = SelfEmploymentSettings(
      enabled: true, deductionLeftE4: AmountE4(whole: 6_500),
      deductionLeftOn: DateOnly(year: 2026, month: 10, day: 1))
    let currencies = [
      CustomCurrency(code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4),
      CustomCurrency(
        code: CurrencyCode("PTS"), name: "Баллы программы лояльности", archived: true),
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      let deps = AppDependencies.forTests(environment)
      let views: [(String, AnyView)] = [
        (
          "self-employment",
          AnyView(
            Form {
              SelfEmploymentSettingsSection(showing: selfEmployed)
              AllocationSettingsSection()
              PlanningHintsSection()
            }.formStyle(.grouped).padding())
        ),
        (
          "currencies",
          AnyView(
            Form { CustomCurrenciesSection(showing: currencies) }.formStyle(.grouped).padding())
        ),
      ]
      for (name, view) in views {
        let controller = NSHostingController(rootView: view.appDependencies(deps))
        let size = controller.sizeThatFits(in: room)
        XCTAssertLessThanOrEqual(
          size.width, room.width + 0.5, "«\(name)» in \(choice) asks for \(size.width) pt")
      }
      environment.language.choice = .system
    }
  }
}
