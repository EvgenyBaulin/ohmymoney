import AppCore
import Foundation

/// The words of the Subscriptions screen, the terms editor and the notices, apart from the views
/// so a test reads each in both languages. Every line says what it is about in words; a symbol
/// and a colour only back it up.
@MainActor
enum SubscriptionsText {
  static let table = "Subscriptions"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  static func count(_ key: String, _ environment: AppEnvironment, _ count: Int) -> String {
    environment.language.format(key, table: table, counts: count)
  }

  /// «+60 ₽» / «−60 ₽»: a change with its sign (U+2212), never by colour alone.
  static func signed(_ amount: AmountE4, _ environment: AppEnvironment) -> String {
    let body = environment.money.rounded(amount.magnitude)
    if amount.raw > 0 { return "+" + body }
    if amount.raw < 0 { return "\u{2212}" + body }
    return body
  }

  static func percent(_ value: Decimal, _ environment: AppEnvironment) -> String {
    let body = NumberText.decimal(value.magnitude, fractionDigits: 0...1)
    let sign = value > 0 ? "+" : (value < 0 ? "\u{2212}" : "")
    return sign + body + (environment.language.resolvedCode == "ru" ? "\u{00A0}%" : "%")
  }

  static func wholePercent(_ value: Int, _ environment: AppEnvironment) -> String {
    String(value) + (environment.language.resolvedCode == "ru" ? "\u{00A0}%" : "%")
  }

  // MARK: Lines

  /// «599 ₽ в месяц · 7 188 ₽ в год»: the cost in rubles; a subscription without a rate for its
  /// currency is told in its own currency and says it is left out of the sums.
  static func cost(_ line: SubscriptionLine, _ environment: AppEnvironment) -> String {
    let money = environment.money
    let currency = line.payment.currency
    let monthly =
      line.monthlyRub.map { money.rounded($0) } ?? money.rounded(line.monthly, currency: currency)
    let yearly =
      line.yearlyRub.map { money.rounded($0) } ?? money.rounded(line.yearly, currency: currency)
    return f("subs.row.cost", environment, monthly, yearly)
  }

  /// «Обычная цена 599 ₽» under the name: what one charge is, in the currency of the payment.
  static func charge(_ line: SubscriptionLine, _ environment: AppEnvironment) -> String {
    f(
      "subs.row.charge", environment,
      environment.money.exact(line.price, currency: line.payment.currency),
      rhythm(line.payment, environment))
  }

  static func rhythm(_ payment: ScheduledPayment, _ environment: AppEnvironment) -> String {
    let key: String
    switch (payment.freq, payment.interval) {
    case (.weekly, _): key = "subs.rhythm.weekly"
    case (.monthly, 1): key = "subs.rhythm.monthly"
    case (.monthly, _): key = "subs.rhythm.months"
    case (.yearly, 1): key = "subs.rhythm.yearly"
    case (.yearly, _): key = "subs.rhythm.years"
    }
    return payment.interval > 1 && payment.freq != .weekly
      ? count(key, environment, payment.interval) : t(key, environment)
  }

  static func comparison(_ comparison: BillingComparison, _ environment: AppEnvironment) -> String {
    let money = environment.money
    switch comparison.cheaper {
    case .yearly:
      return f(
        "subs.row.compare.yearly", environment, money.rounded(comparison.yearlyPlan),
        money.rounded(comparison.twelveMonths), money.rounded(comparison.saving),
        wholePercent(comparison.savingPercent, environment),
        NumberText.decimal(comparison.equivalentMonths, fractionDigits: 0...1))
    case .monthly:
      return f(
        "subs.row.compare.monthly", environment, money.rounded(comparison.twelveMonths),
        money.rounded(comparison.yearlyPlan), money.rounded(-comparison.saving))
    case .same:
      return f("subs.row.compare.same", environment, money.rounded(comparison.twelveMonths))
    }
  }

  static func family(
    _ share: FamilyShare, names: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let people = share.others.map { names[$0.personId] ?? "—" }.joined(separator: ", ")
    return f(
      "subs.row.family", environment, people, environment.money.rounded(share.mine),
      environment.money.rounded(share.total))
  }

  static func usage(_ usage: UsageValue, _ environment: AppEnvironment) -> String? {
    guard usage.hasMarks else { return nil }
    if let perUse = usage.perUseRub {
      return f(
        "subs.row.usage", environment, String(usage.usedDays), environment.money.rounded(perUse))
    }
    return usage.lastUsed.map {
      f("subs.row.usageNone", environment, environment.dates.longDay($0))
    }
  }

  static func band(_ band: FloatingBand, _ environment: AppEnvironment) -> String {
    f(
      "subs.row.band", environment, environment.money.rounded(band.center),
      wholePercent(band.tolerancePercent, environment), environment.money.rounded(band.low),
      environment.money.rounded(band.high))
  }

  static func step(
    _ step: SubscriptionsPage.PriceStep, currency: CurrencyCode, _ environment: AppEnvironment
  ) -> String {
    let money = environment.money
    return f(
      "subs.step", environment, environment.dates.longDay(step.date),
      money.exact(step.oldPrice, currency: currency), money.exact(step.newPrice, currency: currency)
    )
  }

  /// «Подорожала на 180 ₽: сервис +60 ₽ (+10 %), курс +120 ₽ (+7 %)»: the rise in rubles told
  /// apart into what the service did and what the exchange rate did.
  static func split(_ split: PriceChangeSplit, _ environment: AppEnvironment) -> String {
    let key = split.totalRub.raw >= 0 ? "subs.step.splitUp" : "subs.step.splitDown"
    return f(
      key, environment, environment.money.rounded(split.totalRub.magnitude),
      signed(split.servicePartRub, environment),
      split.servicePercent.map { percent($0, environment) } ?? "—",
      signed(split.ratePartRub, environment),
      split.ratePercent.map { percent($0, environment) } ?? "—")
  }

  // MARK: Notices

  static func notice(
    _ notice: SubscriptionNotice, names: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let name = names[notice.paymentId] ?? "—"
    let money = environment.money
    let day = environment.dates.dayAndMonth(notice.day)
    switch notice.kind {
    case .trialEnding:
      return f(
        notice.day == environment.today ? "subs.notice.trialToday" : "subs.notice.trialTomorrow",
        environment, name, money.rounded(notice.amount, currency: notice.currency))
    case .yearlyCharge:
      return f(
        "subs.notice.yearly", environment, name, day,
        money.rounded(notice.amount, currency: notice.currency))
    case .floatingOutside:
      guard let band = notice.band else { return name }
      return f(
        "subs.notice.floating", environment, name,
        money.rounded(notice.amount, currency: notice.currency),
        money.rounded(band.low, currency: notice.currency),
        money.rounded(band.high, currency: notice.currency))
    }
  }

  static func symbol(_ kind: SubscriptionNotice.Kind) -> String {
    switch kind {
    case .trialEnding: "hourglass"
    case .yearlyCharge: "calendar.badge.clock"
    case .floatingOutside: "exclamationmark.triangle"
    }
  }

  // MARK: Types

  static func typeName(_ type: ServiceType, _ environment: AppEnvironment) -> String {
    t(type.key, environment)
  }

  // MARK: Every key

  /// Every key the screen reads from its catalog, so a test finds each in both languages.
  static let keys: [String] =
    [
      "subs.title", "subs.subtitle", "subs.open", "subs.empty", "subs.hero.caption",
      "subs.hero.yearDay", "subs.hero.noRate", "subs.notices", "subs.notice.later",
      "subs.notice.trialToday", "subs.notice.trialTomorrow", "subs.notice.yearly",
      "subs.notice.floating", "subs.advice", "subs.advice.saving", "subs.advice.unused",
      "subs.advice.unusedNever", "subs.advice.duplicates", "subs.advice.needed",
      "subs.advice.keepBoth", "subs.advice.cancel", "subs.row.cost", "subs.row.charge",
      "subs.row.noRate", "subs.row.trial", "subs.row.endsOn", "subs.row.compare.yearly",
      "subs.row.compare.monthly", "subs.row.compare.same", "subs.row.family", "subs.row.usage",
      "subs.row.usageNone", "subs.row.band", "subs.row.unused", "subs.row.needed",
      "subs.row.history", "subs.step", "subs.step.splitUp", "subs.step.splitDown",
      "subs.action.used", "subs.action.terms", "subs.action.edit", "subs.action.cancel",
      "subs.action.cancelLink", "subs.rhythm.weekly", "subs.rhythm.monthly",
      "subs.rhythm.months", "subs.rhythm.yearly", "subs.rhythm.years", "subs.appStore",
      "subs.cancel.title", "subs.cancel.from", "subs.cancel.confirm", "subs.cancel.message",
      "subs.terms.title", "subs.terms.plans", "subs.terms.yearlyPlan", "subs.terms.monthlyPlan",
      "subs.terms.floating", "subs.terms.tolerance", "subs.terms.toleranceAuto",
      "subs.terms.type", "subs.terms.typeAuto", "subs.terms.needed", "subs.terms.neededNote",
      "subs.terms.yearlyReminder", "subs.terms.people", "subs.terms.peopleNote",
      "subs.terms.ownerUses", "subs.terms.save", "subs.terms.cancel", "subs.calendar.only",
      "subs.calendar.none", "subs.calendar.paid", "subs.calendar.coming", "subs.calendar.total",
      "subs.calendar.bunched", "subs.tile.none", "subs.tile.perYear", "subs.tile.count",
      "why.subs.none", "why.subs.total", "why.subs.withoutRate",
    ] + ServiceType.allCases.map(\.key)
}
