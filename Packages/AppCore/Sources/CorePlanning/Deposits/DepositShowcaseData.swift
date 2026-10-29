import CoreKit
import Foundation

/// The deposits built into the app, read from the banks' own pages (and, where noted, from a
/// published review) on the day each entry carries. They change with a release: a rate older than
/// 30 days is shown grey. Rates the banks print as «до» are the highest of the product and are
/// marked as such. A condition the page did not state is left out (`nil`), never guessed; banks
/// whose pages could not be read have no rate at all.
public enum DepositShowcaseData {
  /// The day this list was read; also the version of the list.
  public static let readOn = DateOnly(year: 2026, month: 10, day: 28)

  private static func rub(_ whole: Int64) -> AmountE4 { AmountE4(raw: whole * 10_000) }

  /// A rate read exactly: a decimal literal would pass through binary floating point.
  private static func pct(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
  }

  public static let entries: [DepositShowcaseEntry] = [
    // sberbank.ru/ru/person/contributions/deposits
    DepositShowcaseEntry(
      id: "sber.best", bankName: "Сбербанк", product: "Лучший %", ratePercent: pct("13.5"),
      rateIsMaximum: true, termMinMonths: 1, minAmountE4: rub(100_000), newClientOnly: false,
      rateOn: readOn, note: "new money only"),
    DepositShowcaseEntry(
      id: "sber.start", bankName: "Сбербанк", product: "Выгодный старт +", ratePercent: pct("19"),
      termMinMonths: 3, termMaxMonths: 3, minAmountE4: rub(10_000), newClientOnly: true,
      rateOn: readOn),
    // vtb.ru/personal/vklady-i-scheta
    DepositShowcaseEntry(
      id: "vtb.rub", bankName: "ВТБ", product: "ВТБ-Вклад в рублях", ratePercent: pct("14"),
      rateIsMaximum: true, termMinMonths: 2, termMaxMonths: 36, minAmountE4: rub(10_000),
      rateOn: readOn),
    DepositShowcaseEntry(
      id: "vtb.start", bankName: "ВТБ", product: "Выгодное начало", ratePercent: pct("15"),
      termMinMonths: 3, termMaxMonths: 3, minAmountE4: rub(10_000), newClientOnly: true,
      rateOn: readOn),
    // tbank.ru/savings/deposit
    DepositShowcaseEntry(
      id: "tbank.rub", bankName: "Т-Банк", product: "Вклад в рублях", ratePercent: pct("12.3"),
      rateIsMaximum: true, termMinMonths: 1, termMaxMonths: 24, minAmountE4: rub(50_000),
      rateOn: readOn),
    // gazprombank.ru/personal/increase/deposits
    DepositShowcaseEntry(
      id: "gpb.newmoney", bankName: "Газпромбанк", product: "Новые деньги",
      ratePercent: pct("13.6"),
      rateIsMaximum: true, termMinMonths: 2, termMaxMonths: 36, minAmountE4: rub(15_000),
      maxAmountE4: rub(10_000_000), topup: false, rateOn: readOn, note: "new money only"),
    DepositShowcaseEntry(
      id: "gpb.plus", bankName: "Газпромбанк", product: "В Плюсе", ratePercent: pct("13.6"),
      rateIsMaximum: true, termMinMonths: 1, termMaxMonths: 36, minAmountE4: rub(15_000),
      topup: false, rateOn: readOn),
    // rshb.ru/natural/deposits
    DepositShowcaseEntry(
      id: "rshb.own", bankName: "Россельхозбанк", product: "Свой вклад", ratePercent: pct("13.5"),
      rateIsMaximum: true, termMaxMonths: 48, minAmountE4: rub(5_000), rateOn: readOn),
    // sovcombank.ru/deposits
    DepositShowcaseEntry(
      id: "sovcom.autumn", bankName: "Совкомбанк", product: "Щедрая осень",
      ratePercent: pct("17.5"),
      rateIsMaximum: true, termMinMonths: 3, termMaxMonths: 36, minAmountE4: rub(50_000),
      needsSubscription: true, topup: true, rateOn: readOn,
      note: "highest rate needs the bank's card and subscription"),
    DepositShowcaseEntry(
      id: "sovcom.flexible", bankName: "Совкомбанк", product: "Гибкий", ratePercent: pct("13.8"),
      rateIsMaximum: true, termMinMonths: 2, termMaxMonths: 24, minAmountE4: rub(10_000),
      topup: true, rateOn: readOn),
    // brobank.ru/stavki-po-vkladam-v-oktyabre-2026-goda: maxima of the review of 12 October
    DepositShowcaseEntry(
      id: "alfa.new", bankName: "Альфа-Банк", ratePercent: pct("14.5"), rateIsMaximum: true,
      maxAmountE4: rub(1_000_000), newClientOnly: true,
      rateOn: DateOnly(year: 2026, month: 10, day: 12)),
    DepositShowcaseEntry(
      id: "domrf.new", bankName: "Дом.РФ", ratePercent: pct("14.5"), rateIsMaximum: true,
      newClientOnly: true, rateOn: DateOnly(year: 2026, month: 10, day: 12)),
    DepositShowcaseEntry(
      id: "uralsib", bankName: "Уралсиб", ratePercent: pct("14"), rateIsMaximum: true,
      termMaxMonths: 12, rateOn: DateOnly(year: 2026, month: 10, day: 12)),
    // Pages that could not be read: listed without a rate.
    DepositShowcaseEntry(id: "psb", bankName: "ПСБ", rateOn: readOn),
  ]
}
