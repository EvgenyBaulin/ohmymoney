import CoreKit
import Foundation

@testable import CoreCSV

/// Synthetic statements with the structure of the real bank files and invented content:
/// invented people, phones, shops and sums. Nothing here comes from a real statement.
enum StatementFixtures {
  // MARK: Format B (semicolon, every field quoted, no bank named)

  static let raiffeisenHeader =
    #"Дата операции;Выполнено банком;Номер документа;Сумма в валюте операции (поступления);Сумма в валюте операции (расходы);Валюта операции;Сумма в валюте счета (поступления);Сумма в валюте счета (расходы);Валюта счета;Детали операции (назначение платежа);Номер карты"#

  struct RaiffRow {
    var moment: String
    var done: String
    var doc: String
    var income: String
    var expense: String
    var details: String
    var card: String
  }

  static func raiffeisenLine(_ row: RaiffRow) -> String {
    let currency = "RUB"
    let fields = [
      row.moment, row.done, row.doc, row.income, row.expense, currency,
      row.income, row.expense, currency, row.details, row.card,
    ]
    return fields.map { "\"\($0)\"" }.joined(separator: ";")
  }

  /// Rows covering every wording template of the format. Row order is part of the tests.
  static let raiffeisenRows: [RaiffRow] = [
    RaiffRow(
      moment: "14.09.2026 10:15", done: "15.09.2026", doc: "DOC0001", income: "", expense: "150,00",
      details: " SAMPLE CAFE", card: "*1111"),
    RaiffRow(
      moment: "14.09.2026 10:15", done: "15.09.2026", doc: "DOC0002", income: "", expense: "150,00",
      details: " SAMPLE CAFE", card: "*1111"),
    RaiffRow(
      moment: "14.09.2026 11:00", done: "В обработке", doc: "DOC0003", income: "",
      expense: "2 208,50", details: " SAMPLE SHOP", card: "*1111"),
    RaiffRow(
      moment: "14.09.2026 12:00", done: "15.09.2026", doc: "DOC0004", income: "",
      expense: "3 300,00",
      details:
        " Телефон получателя 79001112233 Сообщение  Идентификатор операции СБП A123456 Банк получателя Яндекс",
      card: ""),
    RaiffRow(
      moment: "13.09.2026 09:00", done: "13.09.2026", doc: "", income: "10 000,00", expense: "",
      details: " Анна Ивановна Т На отпуск На отпуск На счет: *2222", card: ""),
    RaiffRow(
      moment: "13.09.2026 09:30", done: "13.09.2026", doc: "DOC0006", income: "", expense: "500,00",
      details:
        " Перевели: Иван П. Перевод средств по номеру телефона На счет: *3333 Со счета: *2222",
      card: ""),
    RaiffRow(
      moment: "12.09.2026 08:00", done: "12.09.2026", doc: "DOC0007", income: "", expense: "590,00",
      details: " КИОН Оплата услуг КИОН Оплата услуг Со счета: *2222", card: ""),
    RaiffRow(
      moment: "12.09.2026 08:10", done: "12.09.2026", doc: "DOC0008", income: "", expense: "300,00",
      details: " Провайдер услуг Мобильная связь Телефон 79001112233", card: ""),
    RaiffRow(
      moment: "05.09.2026 00:00", done: "05.09.2026", doc: "DOC0009", income: "124,00", expense: "",
      details: " Кэшбэк за сентябрь На счет: *2222", card: ""),
    RaiffRow(
      moment: "11.09.2026 15:00", done: "11.09.2026", doc: "DOC0010", income: "990,00", expense: "",
      details: " Возврат от SAMPLE SHOP", card: "*1111"),
    RaiffRow(
      moment: "10.09.2026 09:00", done: "10.09.2026", doc: "DOC0011", income: "25 000,00",
      expense: "", details: " Вознагр.по дог.ГПХ за 09.2026 ООО Пример", card: ""),
    RaiffRow(
      moment: "10.09.2026 10:00", done: "10.09.2026", doc: "", income: "1 000,00", expense: "",
      details: " Т-Банк", card: "*1111"),
    RaiffRow(
      moment: "09.09.2026 20:00", done: "10.09.2026", doc: "DOC0013", income: "", expense: "946,40",
      details: " CARD **1111 11AUG RUB 946.40 SAMPLESHOP", card: "*1111"),
    RaiffRow(
      moment: "08.09.2026 10:00", done: "08.09.2026", doc: "", income: "700,00", expense: "",
      details: " Пришел перевод: Алексей В.", card: ""),
    RaiffRow(
      moment: "08.09.2026 11:00", done: "08.09.2026", doc: "DOC0015", income: "",
      expense: "1 000,00", details: " Рублевый перевод между счетами", card: ""),
    RaiffRow(
      moment: "08.09.2026 12:00", done: "08.09.2026", doc: "DOC0016", income: "12,00", expense: "",
      details: " Кэшбэк от SAMPLE MARKET На счет: *2222", card: ""),
    RaiffRow(
      moment: "08.09.2026 13:00", done: "08.09.2026", doc: "", income: "300,00", expense: "",
      details: " Мария А Мария Мария На счет: *2222", card: ""),
    RaiffRow(
      moment: "08.09.2026 14:00", done: "08.09.2026", doc: "DOC0018", income: "", expense: "100,00",
      details: " Телефон получателя 79001112233 Банк получателя Сбербанк", card: ""),
    RaiffRow(
      moment: "08.09.2026 15:00", done: "08.09.2026", doc: "DOC0019", income: "", expense: "400,00",
      details:
        " Телефон получателя 79001112233 Сообщение За обед Идентификатор операции СБП X9 Банк получателя Т-Банк",
      card: ""),
  ]

  /// The file as a bank writes it: a byte-order mark, mixed line endings.
  static func raiffeisenCSV(rows: [RaiffRow] = raiffeisenRows) -> Data {
    var text = "\u{FEFF}" + raiffeisenHeader
    for (index, row) in rows.enumerated() {
      text += (index % 2 == 0 ? "\r\n" : "\n") + raiffeisenLine(row)
    }
    return Data((text + "\r\n").utf8)
  }

  // MARK: Format A (semicolon, no quotes)

  static let vtbHeader =
    "Название продукта;Карта;Номер счёта/Кредитного договора;Дата и время операции;Списание/Зачисление;Сумма в валюте операции;Валюта операции;Сумма в валюте счёта;Валюта счёта;Комиссия в валюте счёта;Кешбэк;Наименование операции;Тип операции;Категория;Наименование ТСП;Код МСС;Комментарий к операции;Статус операции"

  static let vtbLines: [String] = [
    // 0 purchase with cashback
    "Мастер-счёт в рублях;220024******1111;40817810000000000402;14.09.2026 10:15;Списание;-1786,0;RUB;-1786,0;RUB;0,0;130,0;АЗС;Оплата товаров и услуг;Транспорт;FUEL 12345_INT;5541;;Операция выполнена",
    // 1 incoming transfer
    "Мастер-счёт в рублях;;40817810000000000402;13.09.2026 09:00;Зачисление;5000,0;RUB;5000,0;RUB;0,0;0,0;Анна Ивановна Т;Входящий перевод СБП;Входящие переводы;;;;Операция выполнена",
    // 2 sign contradicts the word
    "Мастер-счёт в рублях;;40817810000000000402;12.09.2026 09:00;Списание;700,0;RUB;700,0;RUB;0,0;0,0;Исходящий;Исходящий перевод СБП;Переводы;;;;Операция выполнена",
    // 3 declined
    "Мастер-счёт в рублях;220024******1111;40817810000000000402;12.09.2026 10:00;Списание;-3588,0;RUB;-3588,0;RUB;0,0;0,0;Покупки;Оплата товаров и услуг;Покупки;SAMPLE STORE;5311;;Операция отклонена",
    // 4 pending
    "Мастер-счёт в рублях;220024******1111;40817810000000000402;11.09.2026 10:00;Списание;-250,0;RUB;-250,0;RUB;0,0;0,0;Кафе;Оплата товаров и услуг;Кафе;SAMPLE CAFE;5812;;В обработке",
    // 5 cash deposit, trailing blank in the type
    "Мастер-счёт в рублях;;40817810000000000402;10.09.2026 10:00;Зачисление;2000,0;RUB;2000,0;RUB;0,0;0,0;Наличные;\"Внесение наличных через ATM \";Операции с наличными;;;;Операция выполнена",
    // 6 purchase with a fee
    "Мастер-счёт в рублях;220024******1111;40817810000000000402;09.09.2026 10:00;Списание;-1000,0;RUB;-1000,0;RUB;15,0;0,0;Снятие;Оплата товаров и услуг;Прочее;SAMPLE KIOSK MOSCOW RUS;5499;Комментарий;Операция выполнена",
    // 7 wrong column count
    "Мастер-счёт в рублях;;40817810000000000402;08.09.2026 10:00",
  ]

  static func vtbCSV() -> Data {
    Data(("\u{FEFF}" + ([vtbHeader] + vtbLines).joined(separator: "\n") + "\n").utf8)
  }

  // MARK: Format C (text layer of a PDF)

  struct TBankRow {
    var opDate = "15.09.2026"
    var postDate = "15.09.2026"
    var amountCents: Int
    var description: String
    var card: String
    var time = "10:15"
    var postTime = "10:20"
    /// Description continuation on the time line and on further lines.
    var timeLineText = ""
    var more: [String] = []
    /// Put a single space between description and card, as one real line does.
    var tightCard = false
  }

  static func money(_ cents: Int, decimalComma: Bool = false, signed: Bool = true) -> String {
    let magnitude = abs(cents)
    let whole = magnitude / 100
    let frac = String(format: "%02d", magnitude % 100)
    var digits = String(whole)
    var grouped = ""
    while digits.count > 3 {
      grouped = " " + digits.suffix(3) + grouped
      digits = String(digits.dropLast(3))
    }
    grouped = digits + grouped
    let sign = signed ? (cents < 0 ? "-" : "+") : ""
    return "\(sign)\(grouped)\(decimalComma ? "," : ".")\(frac) ₽"
  }

  static let tbankHead: [String] = [
    "                                                                       АО «ТБанк»",
    "                                                                       г. Москва, ул. Пример, д. 1",
    "",
    "Справка о движении средств",
    "Номер договора: 1000000001",
    "Дата заключения договора: 01.01.2026",
    "Номер лицевого счета: 40817810000000000001",
    "Движение средств за период с 01.09.2026 по 30.09.2026",
  ]

  static let tbankTableHead: [String] = [
    "Дата и время       Дата и время        Сумма в валюте     Сумма операции     Описание операции             Номер карты",
    "операции           списания            операции           в валюте карты",
  ]

  static let tbankPageBreak: [String] = [
    "               АО «ТБанк» универсальная лицензия № 2673, р/с 30101810145250000974 в ГУ Банка России",
    "                          БИК 044525974 ИНН 7710140679 КПП 771301001",
    "                                                  2",
  ]

  static func tbankRowLines(_ row: TBankRow) -> [String] {
    let gap = row.tightCard ? " " : "    "
    var lines = [
      row.opDate.padding(toLength: 20, withPad: " ", startingAt: 0)
        + row.postDate.padding(toLength: 20, withPad: " ", startingAt: 0)
        + money(row.amountCents).padding(toLength: 26, withPad: " ", startingAt: 0)
        + money(row.amountCents).padding(toLength: 25, withPad: " ", startingAt: 0)
        + row.description + gap + row.card
    ]
    var timeLine =
      row.time.padding(toLength: 20, withPad: " ", startingAt: 0)
      + row.postTime.padding(toLength: 20, withPad: " ", startingAt: 0)
    if !row.timeLineText.isEmpty {
      timeLine += String(repeating: " ", count: 51) + row.timeLineText
    }
    lines.append(timeLine)
    lines.append(contentsOf: row.more.map { String(repeating: " ", count: 91) + $0 })
    return lines
  }

  static let tbankRows: [TBankRow] = [
    TBankRow(
      amountCents: 5_000_000, description: "Пополнение. Система быстрых платежей", card: "1111"),
    TBankRow(
      amountCents: -301_400, description: "Оплата в SAMPLE SHOP MOSCOW RUS", card: "1111",
      time: "11:00", postTime: "11:05"),
    TBankRow(
      amountCents: -100_000, description: "Внешний перевод по", card: "—", time: "12:00",
      postTime: "12:00", timeLineText: "номеру телефона", more: ["+70001112233"]),
    TBankRow(
      amountCents: -84_100, description: "Оплата в SAMPLE.TECH G TULA", card: "1111", time: "13:00",
      postTime: "13:01", tightCard: true),
    TBankRow(
      amountCents: 1_234, description: "Кэшбэк за обычные покупки", card: "1111", time: "14:00",
      postTime: "14:00"),
    TBankRow(
      amountCents: -5_900, description: "Комиссия за использование Кубышки", card: "—",
      time: "03:00", postTime: "03:00"),
    TBankRow(
      amountCents: -1_000_000, description: "Внутренний перевод на договор 1000000002", card: "—",
      time: "16:00", postTime: "16:00"),
  ]

  static func tbankLines(
    rows: [TBankRow] = tbankRows, footerIncome: Int? = nil, footerExpense: Int? = nil,
    pageBreakAfter: Int? = 3
  ) -> [String] {
    var lines = tbankHead + tbankTableHead
    for (index, row) in rows.enumerated() {
      lines += tbankRowLines(row)
      if let pageBreakAfter, index == pageBreakAfter {
        lines += tbankPageBreak + tbankTableHead
      }
    }
    let income = footerIncome ?? rows.map(\.amountCents).filter { $0 > 0 }.reduce(0, +)
    let expense = footerExpense ?? -rows.map(\.amountCents).filter { $0 < 0 }.reduce(0, +)
    lines += [
      "",
      "Пополнения:    " + money(income, decimalComma: true, signed: false),
      "Расходы:       " + money(expense, decimalComma: true, signed: false),
      "",
      "С уважением,",
      "Руководитель дополнительного офиса                                  Т.Т. Пример",
    ]
    lines += tbankPageBreak
    return lines
  }
}
