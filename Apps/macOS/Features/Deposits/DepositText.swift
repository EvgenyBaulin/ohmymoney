import AppCore
import Foundation

/// The words of the showcase of deposits, of the line when a deposit ends, and of dividends and
/// coupons — one String Catalog (`Deposits`), both languages.
@MainActor
enum DepositText {
  static let table = "Deposits"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// «до 13.5 %», «14 %», or «Уточните на сайте банка» when the rate is not known.
  static func rate(_ entry: DepositShowcaseEntry, _ environment: AppEnvironment) -> String {
    guard let rate = entry.ratePercent else { return t("dep.rate.unknown", environment) }
    return f(entry.rateIsMaximum ? "dep.rate.upTo" : "dep.rate.exact", environment, "\(rate)")
  }

  /// «3–36 мес.», «от 1 мес.», «до 12 мес.», «6 мес.»; empty when the source says nothing.
  static func term(_ entry: DepositShowcaseEntry, _ environment: AppEnvironment) -> String? {
    switch (entry.termMinMonths, entry.termMaxMonths) {
    case (let low?, let high?) where low == high: f("dep.term.one", environment, low)
    case (let low?, let high?): f("dep.term.range", environment, low, high)
    case (let low?, nil): f("dep.term.from", environment, low)
    case (nil, let high?): f("dep.term.upTo", environment, high)
    case (nil, nil): nil
    }
  }

  static func amount(_ entry: DepositShowcaseEntry, _ environment: AppEnvironment) -> String? {
    let money = environment.money
    switch (entry.minAmountE4, entry.maxAmountE4) {
    case (let low?, let high?):
      return f("dep.amount.range", environment, money.rounded(low), money.rounded(high))
    case (let low?, nil): return f("dep.amount.from", environment, money.rounded(low))
    case (nil, let high?): return f("dep.amount.upTo", environment, money.rounded(high))
    case (nil, nil): return nil
    }
  }

  /// The conditions of an entry in one line: term, amount, new clients, subscription, top-up.
  static func details(_ entry: DepositShowcaseEntry, _ environment: AppEnvironment) -> String {
    var parts: [String] = []
    if let term = term(entry, environment) { parts.append(term) }
    if let amount = amount(entry, environment) { parts.append(amount) }
    if entry.newClientOnly { parts.append(t("dep.newClient", environment)) }
    if entry.needsSubscription { parts.append(t("dep.subscription", environment)) }
    switch entry.topup {
    case true?: parts.append(t("dep.topup.yes", environment))
    case false?: parts.append(t("dep.topup.no", environment))
    case nil: break
    }
    return parts.joined(separator: " · ")
  }

  /// «ставка на 28 октября» and, past 30 days, «могла измениться».
  static func rateDate(
    _ entry: DepositShowcaseEntry, today: DateOnly, _ environment: AppEnvironment
  ) -> String {
    guard entry.ratePercent != nil else { return "" }
    var text = f("dep.rateOn", environment, environment.dates.dayAndMonth(entry.rateOn))
    if entry.isStale(on: today) { text += " · " + t("dep.stale", environment) }
    return text
  }

  /// «дивиденды» or «купон»: the mark of a payout in the lists and the calendar.
  static func payoutTag(_ kind: PayoutKind, _ environment: AppEnvironment) -> String {
    t(kind == .dividend ? "payout.tag.dividend" : "payout.tag.coupon", environment)
  }

  /// «Т-Банк — до 12.3 %».
  static func pick(_ entry: DepositShowcaseEntry, _ environment: AppEnvironment) -> String {
    "\(entry.bankName) — \(rate(entry, environment))"
  }

  /// «Вклад «Накопительный» кончится 3 ноября. Сейчас в витрине (не финансовая консультация):»
  /// and one line per condition.
  static func endsLine(
    _ advice: DepositEndAdvice, accounts: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let head = f(
      "look.depositEnds", environment, accounts[advice.accountId] ?? "—",
      environment.dates.dayAndMonth(advice.endsOn))
    let lines = advice.picks.map { pick -> String in
      switch pick.condition {
      case .term(let months):
        return f("dep.pick.term", environment, months, Self.pick(pick.entry, environment))
      case .amount(let amount):
        return f(
          "dep.pick.amount", environment, environment.money.rounded(amount),
          Self.pick(pick.entry, environment))
      case .topup:
        return f("dep.pick.topup", environment, Self.pick(pick.entry, environment))
      }
    }
    return ([head] + lines).joined(separator: "\n")
  }

  /// The advice for the deposits of a snapshot, against the built-in list and the owner's offers.
  static func advice(for snapshot: DataSnapshot) -> [DepositEndAdvice] {
    let balances = snapshot.planning.accounts.balances
    return DepositEndAdvisor.advice(
      accounts: snapshot.dataset.paymentMethods,
      balanceE4: { account in
        balances.balance(
          BalanceKey(accountId: account.id, currency: account.mainCurrency), at: balances.now)
      },
      entries: DepositShowcase.entries(own: snapshot.dataset.depositOffers), today: snapshot.today)
  }

  /// Every key, so a test finds each in both languages.
  static let keys = [
    "dep.title", "dep.subtitle", "dep.version", "dep.filter.term", "dep.filter.amount",
    "dep.filter.topup", "dep.filter.any", "dep.rate.upTo", "dep.rate.exact", "dep.rate.unknown",
    "dep.rateOn", "dep.stale", "dep.term.one", "dep.term.range", "dep.term.from", "dep.term.upTo",
    "dep.amount.range", "dep.amount.from", "dep.amount.upTo", "dep.newClient", "dep.subscription",
    "dep.topup.yes", "dep.topup.no", "dep.own", "dep.none", "dep.add", "dep.form.new",
    "dep.form.edit", "dep.form.bank", "dep.form.rate", "dep.form.term", "dep.form.min",
    "dep.form.max", "dep.form.newClient", "dep.form.subscription", "dep.form.topup",
    "dep.form.rateOn", "dep.form.note", "dep.form.rateInvalid", "dep.pick.term",
    "dep.pick.amount", "dep.pick.topup", "look.depositEnds", "dep.open",
    "crypto.source", "crypto.source.coingecko", "crypto.source.manual", "crypto.source.hint",
    "crypto.coin.source", "crypto.coin.id", "crypto.coin.hint", "crypto.coin.refusal",
    "payout.kind", "payout.none", "payout.dividend", "payout.coupon", "payout.asset",
    "payout.noAssets", "payout.tag.dividend", "payout.tag.coupon", "payout.fromAsset",
    "payout.newTitle", "payout.recurringHint",
  ]
}
