import Foundation

/// The formats the app is built with, as the files an owner would write: the same text, read by
/// the same code. Every example is invented. A text none of them fits is read by the general
/// scan (`BankTextParser`), which knows banks nobody wrote a format for.
public enum SmsBuiltInFormats {
  /// The files, by name.
  public static let files: [(id: String, text: String)] = [
    (
      "sber.purchase",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) (?:Покупка|Оплата) ([\d.]+)р (.+?) Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;outcome;payee;balance
      -----BANK-----
      sber
      -----EXAMPLE-----
      MIR-1111 07:55 Покупка 450р SAMPLE CAFE Баланс: 12300р
      -----EXAMPLE-----
      VISA2222 13:02 Оплата 2380.40р SAMPLE MARKET Баланс: 9919.60р
      """#
    ),
    (
      "sber.purchase.foreign",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) (?:Покупка|Оплата) ([\d.]+)([$€]) (.+?) Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;op_outcome;op_instrument;payee;balance
      -----BANK-----
      sber
      -----EXAMPLE-----
      VISA2222 12:00 Покупка 15.00$ SAMPLE.COM/BILL Баланс: 30000р
      """#
    ),
    (
      "sber.refund",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) Возврат покупки ([\d.]+)р (.+?) Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;income;payee;balance
      -----OPERATION-----
      refund
      -----BANK-----
      sber
      -----EXAMPLE-----
      MIR-1111 16:40 Возврат покупки 1200р SAMPLE SHOP Баланс: 13500р
      """#
    ),
    (
      "sber.cash",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) Выдача наличных ([\d.]+)р (.*?) Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;outcome;;balance
      -----OPERATION-----
      cashWithdrawal
      -----BANK-----
      sber
      -----EXAMPLE-----
      MIR-1111 11:11 Выдача наличных 3000р ATM 556677 Баланс: 10500р
      """#
    ),
    (
      "sber.salary",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) Зарплата ([\d.]+)р Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;income;balance
      -----OPERATION-----
      income
      -----BANK-----
      sber
      -----EXAMPLE-----
      MIR-1111 10:00 Зарплата 120000р Баланс: 131000р
      """#
    ),
    (
      "sber.transferIn",
      #"""
      ^(?:MIR|VISA|MC|MASTERCARD|MAESTRO)-?(\d{4}) (\d{2}:\d{2}) Перевод от (.+?) ([\d.]+)р Баланс: ([\d.]+)р$
      -----COLUMNS-----
      card;time;payee;income;balance
      -----OPERATION-----
      transferIn
      -----BANK-----
      sber
      -----EXAMPLE-----
      MIR-1111 19:30 Перевод от Анна К. 2500р Баланс: 15000р
      """#
    ),
    (
      "tbank.purchase",
      #"""
      ^Покупка, карта \*(\d{4})\. (\d[\d\s]*(?:,\d+)?) ₽\. ((?:(?!\.\s).)+)\. Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      card;outcome;payee;balance
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Покупка, карта *1111. 450 ₽. SAMPLE CAFE. Доступно 12 300 ₽
      -----EXAMPLE-----
      Покупка, карта *1111. 2 380,40 ₽. SAMPLE MARKET. Доступно 9 919,60 ₽
      """#
    ),
    (
      "tbank.purchase.foreign",
      #"""
      ^Покупка, карта \*(\d{4})\. (\d[\d\s]*(?:,\d+)?) ([$€])\. ((?:(?!\.\s).)+)\. Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      card;op_outcome;op_instrument;payee;balance
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Покупка, карта *1111. 9,99 €. SAMPLE MUSIC. Доступно 15 000 ₽
      """#
    ),
    (
      "tbank.refund",
      #"""
      ^Возврат покупки, карта \*(\d{4})\. (\d[\d\s]*(?:,\d+)?) ₽\. ((?:(?!\.\s).)+)\. Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      card;income;payee;balance
      -----OPERATION-----
      refund
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Возврат покупки, карта *1111. 1 200 ₽. SAMPLE SHOP. Доступно 13 500 ₽
      """#
    ),
    (
      "tbank.cash",
      #"""
      ^Снятие наличных, карта \*(\d{4})\. (\d[\d\s]*(?:,\d+)?) ₽\. Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      card;outcome;balance
      -----OPERATION-----
      cashWithdrawal
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Снятие наличных, карта *1111. 3 000 ₽. Доступно 10 500 ₽
      """#
    ),
    (
      "tbank.topup",
      #"""
      ^Пополнение, счет RUB\. (\d[\d\s]*(?:,\d+)?) ₽\. (.+?) Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      income;payee;balance
      -----OPERATION-----
      transferIn
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Пополнение, счет RUB. 2 500 ₽. Анна К. Доступно 15 000 ₽
      """#
    ),
    (
      "tbank.cashback",
      #"""
      ^Кэшбэк, карта \*(\d{4})\. (\d[\d\s]*(?:,\d+)?) ₽\. Доступно (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      card;income;balance
      -----OPERATION-----
      income
      -----BANK-----
      tbank
      -----EXAMPLE-----
      Кэшбэк, карта *1111. 340 ₽. Доступно 15 340 ₽
      """#
    ),
    (
      "vtb.purchase",
      #"""
      ^Карта \*(\d{4}): (?:Покупка|Оплата) ([\d.]+) RUR, ((?:(?!\.\s).)+)\. Доступно ([\d.]+) RUR$
      -----COLUMNS-----
      card;outcome;payee;balance
      -----BANK-----
      vtb
      -----EXAMPLE-----
      Карта *1111: Покупка 450.00 RUR, SAMPLE CAFE. Доступно 12300.00 RUR
      -----EXAMPLE-----
      Карта *1111: Оплата 2380.40 RUR, SAMPLE MARKET. Доступно 9919.60 RUR
      """#
    ),
    (
      "alfa.purchase",
      #"""
      ^Альфа-Банк\. Покупка (\d[\d\s]*(?:,\d+)?) ₽, ((?:(?!\.\s).)+)\. Карта \*(\d{4})\. Остаток (\d[\d\s]*(?:,\d+)?) ₽$
      -----COLUMNS-----
      outcome;payee;card;balance
      -----BANK-----
      alfa
      -----EXAMPLE-----
      Альфа-Банк. Покупка 450 ₽, SAMPLE CAFE. Карта *1111. Остаток 12 300 ₽
      -----EXAMPLE-----
      Альфа-Банк. Покупка 2 380,40 ₽, SAMPLE MARKET. Карта *1111. Остаток 9 919,60 ₽
      """#
    ),
    (
      "alfa.payment",
      #"""
      ^Оплата ([\d.]+) RUR\. ((?:(?!\.\s).)+)\. Карта \*(\d{4})\. Доступно ([\d.]+) RUR$
      -----COLUMNS-----
      outcome;payee;card;balance
      -----BANK-----
      alfa
      -----EXAMPLE-----
      Оплата 1999.00 RUR. SAMPLE DELIVERY. Карта *1111. Доступно 31000.75 RUR
      """#
    ),
    (
      "info.code",
      #"""
      ^(?:Код|Пароль|Code)[:\s]+(\d{4,8})\. .*(?:Никому не сообщайте|Do not share)
      -----COLUMNS-----

      -----EXAMPLE-----
      Код: 123456. Никому не сообщайте его.
      -----EXAMPLE-----
      Code 7777. Do not share it with anyone.
      """#
    ),
  ]

  public static let formats: [SmsFormat] = files.compactMap { file in
    if case .success(let format) = SmsFormat.parse(fileText: file.text, id: file.id) {
      return format
    }
    return nil
  }
}
