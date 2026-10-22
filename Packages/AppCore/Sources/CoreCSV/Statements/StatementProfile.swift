import CoreKit
import Foundation

/// How one bank's statement is recognised and read, as plain data. A new bank, or a new
/// version of a bank's format, is a new profile next to the old ones; the readers never
/// change. Patterns are regular expressions kept as text with numbered groups so a profile
/// can be stored, shipped as a file and compared.
public struct StatementProfile: Sendable, Codable, Hashable, Identifiable {
  public enum Layout: Sendable, Codable, Hashable {
    case delimited(StatementDelimitedLayout)
    case pdfText(StatementPDFTextLayout)
  }

  /// Stable identifier, versioned in its name (`raiffeisen-csv-v1`): a bank that changes its
  /// format gets `…-v2` beside this one.
  public var id: String
  public var bankName: String
  /// False when the file never names the bank, so the first import has to ask which bank and
  /// account it belongs to; `bankName` is then only a suggestion.
  public var fileNamesTheBank: Bool
  /// Time zone of the clock the file's times are written in.
  public var timeZoneID: String
  public var layout: Layout
  public var descriptionRules: [StatementDescriptionRule]

  public init(
    id: String, bankName: String, fileNamesTheBank: Bool, timeZoneID: String = "Europe/Moscow",
    layout: Layout, descriptionRules: [StatementDescriptionRule]
  ) {
    self.id = id
    self.bankName = bankName
    self.fileNamesTheBank = fileNamesTheBank
    self.timeZoneID = timeZoneID
    self.layout = layout
    self.descriptionRules = descriptionRules
  }
}

/// A field of a delimited statement, named independently of the bank's own header.
public enum StatementField: String, Sendable, Codable, Hashable, CaseIterable {
  case product, card, account, moment, posted, documentID
  /// One signed amount column.
  case amount
  /// Two unsigned amount columns, exactly one of them filled in each row.
  case incomeAmount, expenseAmount
  case currency
  case accountAmount, accountIncomeAmount, accountExpenseAmount, accountCurrency
  case direction, fee, cashback
  case title, operationType, bankCategory, merchant, mcc, comment, status, details
}

public struct StatementDelimitedLayout: Sendable, Codable, Hashable {
  public enum AmountStyle: String, Sendable, Codable, Hashable {
    case signed
    case splitIncomeExpense
  }

  /// One character.
  public var delimiter: String
  /// Header names that must all be present for the file to be taken for this format.
  public var requiredHeaders: [String]
  /// `StatementField.rawValue` → header text of the column.
  public var columns: [String: String]
  public var amountStyle: AmountStyle
  /// Fields whose texts, joined with ` | `, are what the description rules read.
  public var descriptionFields: [String]
  /// Words of the debit/credit column; when present the sign must agree with them.
  public var debitWords: [String]
  public var creditWords: [String]
  /// Lower-case fragments that mark a held (not yet posted) row in the status or posting
  /// column, and a refused one in the status column.
  public var pendingMarkers: [String]
  public var declinedMarkers: [String]

  public init(
    delimiter: String, requiredHeaders: [String], columns: [StatementField: String],
    amountStyle: AmountStyle, descriptionFields: [StatementField], debitWords: [String] = [],
    creditWords: [String] = [], pendingMarkers: [String] = [], declinedMarkers: [String] = []
  ) {
    self.delimiter = delimiter
    self.requiredHeaders = requiredHeaders
    self.columns = Dictionary(uniqueKeysWithValues: columns.map { ($0.key.rawValue, $0.value) })
    self.amountStyle = amountStyle
    self.descriptionFields = descriptionFields.map(\.rawValue)
    self.debitWords = debitWords
    self.creditWords = creditWords
    self.pendingMarkers = pendingMarkers
    self.declinedMarkers = declinedMarkers
  }

  func header(of field: StatementField) -> String? { columns[field.rawValue] }
}

/// A statement whose text layer has been extracted: the row is two lines (dates and amounts,
/// then times), followed by continuation lines of the description.
public struct StatementPDFTextLayout: Sendable, Codable, Hashable {
  /// Upper-case fragments that must all occur on the first page.
  public var signatureFragments: [String]
  /// Groups: 1 operation date, 2 posting date, 3 amount, 4 mark of 3 (may be empty),
  /// 5 amount in the account currency, 6 mark of 5, 7 description, 8 card (4 digits or `—`).
  public var rowPattern: String
  /// Groups: 1 operation time, 2 posting time, 3 start of the description (optional).
  public var timePattern: String
  /// Lines that never belong to a description: repeated table heads, page footers.
  public var skipPatterns: [String]
  /// Head and foot facts, each a pattern with the value in group 1 (period: groups 1 and 2).
  public var contractPattern: String
  public var accountPattern: String
  public var openedPattern: String
  public var periodPattern: String
  public var footerIncomePattern: String
  public var footerExpensePattern: String

  public init(
    signatureFragments: [String], rowPattern: String, timePattern: String,
    skipPatterns: [String], contractPattern: String, accountPattern: String,
    openedPattern: String, periodPattern: String, footerIncomePattern: String,
    footerExpensePattern: String
  ) {
    self.signatureFragments = signatureFragments
    self.rowPattern = rowPattern
    self.timePattern = timePattern
    self.skipPatterns = skipPatterns
    self.contractPattern = contractPattern
    self.accountPattern = accountPattern
    self.openedPattern = openedPattern
    self.periodPattern = periodPattern
    self.footerIncomePattern = footerIncomePattern
    self.footerExpensePattern = footerExpensePattern
  }
}

/// One wording of the bank and what it means. Rules are tried in order; the first whose
/// pattern, direction and card condition all fit wins.
public struct StatementDescriptionRule: Sendable, Codable, Hashable {
  public enum Direction: String, Sendable, Codable, Hashable {
    case any, income, expense
  }
  public enum CardCondition: String, Sendable, Codable, Hashable {
    case any, present, absent
  }

  public var id: String
  /// Case-insensitive; the whole description is matched, groups are numbered.
  public var pattern: String
  public var kind: StatementOperationKind
  public var direction: Direction
  public var card: CardCondition
  /// Names of the captured groups in order: `name`, `phone`, `bank`, `message`, `merchant`,
  /// `contract`, `cardMask`, `month`. An empty name skips the group.
  public var groups: [String]

  public init(
    id: String, pattern: String, kind: StatementOperationKind,
    direction: Direction = .any, card: CardCondition = .any, groups: [String] = []
  ) {
    self.id = id
    self.pattern = pattern
    self.kind = kind
    self.direction = direction
    self.card = card
    self.groups = groups
  }
}

/// The bank formats known so far. The list is data: adding a bank means adding a profile and
/// a fixture, never touching the readers.
public enum StatementProfiles {
  public static let all: [StatementProfile] = [vtbCSV, raiffeisenCSV, tbankPDF]

  public static func profile(id: String) -> StatementProfile? { all.first { $0.id == id } }

  private static let person = #"\p{Lu}\p{Ll}+(?:-\p{Lu}\p{Ll}+)?"#

  /// VTB account statement, `;`-separated. Written from the format description alone: there
  /// is no sample file of it in the test fixtures, so the wording rules are the conservative
  /// minimum and anything else falls to `unknown` and the question queue.
  public static let vtbCSV = StatementProfile(
    id: "vtb-csv-v1", bankName: "ВТБ", fileNamesTheBank: true,
    layout: .delimited(
      StatementDelimitedLayout(
        delimiter: ";",
        requiredHeaders: [
          "Название продукта", "Номер счёта/Кредитного договора", "Дата и время операции",
        ],
        columns: [
          .product: "Название продукта", .card: "Карта",
          .account: "Номер счёта/Кредитного договора", .moment: "Дата и время операции",
          .direction: "Списание/Зачисление", .amount: "Сумма в валюте операции",
          .currency: "Валюта операции", .accountAmount: "Сумма в валюте счёта",
          .accountCurrency: "Валюта счёта", .fee: "Комиссия в валюте счёта",
          .cashback: "Кешбэк", .title: "Наименование операции", .operationType: "Тип операции",
          .bankCategory: "Категория", .merchant: "Наименование ТСП", .mcc: "Код МСС",
          .comment: "Комментарий к операции", .status: "Статус операции",
        ],
        amountStyle: .signed, descriptionFields: [.operationType, .title],
        debitWords: ["Списание"], creditWords: ["Зачисление"],
        pendingMarkers: ["в обработке"], declinedMarkers: ["отклонен"])),
    descriptionRules: [
      rule("vtb-sbp-out", #"^Исходящий перевод СБП\s*\|\s*(.*)$"#, .sbpTransferOut, ["name"]),
      rule("vtb-sbp-in", #"^Входящий перевод СБП\s*\|\s*(.*)$"#, .sbpTransferIn, ["name"]),
      rule("vtb-cash-in", #"^Внесение наличных"#, .cashDeposit),
      rule("vtb-cashback", #"^Зачисление ке[шэ]бэка"#, .cashbackPayout),
      rule("vtb-fee", #"^Комиссия"#, .bankFee),
      rule("vtb-purchase", #"^Оплата товаров и услуг"#, .purchase),
    ])

  /// Raiffeisen current-account statement. The file never names the bank.
  public static let raiffeisenCSV = StatementProfile(
    id: "raiffeisen-csv-v1", bankName: "Райффайзен", fileNamesTheBank: false,
    layout: .delimited(
      StatementDelimitedLayout(
        delimiter: ";",
        requiredHeaders: [
          "Дата операции", "Выполнено банком", "Детали операции (назначение платежа)",
        ],
        columns: [
          .moment: "Дата операции", .posted: "Выполнено банком", .documentID: "Номер документа",
          .incomeAmount: "Сумма в валюте операции (поступления)",
          .expenseAmount: "Сумма в валюте операции (расходы)", .currency: "Валюта операции",
          .accountIncomeAmount: "Сумма в валюте счета (поступления)",
          .accountExpenseAmount: "Сумма в валюте счета (расходы)",
          .accountCurrency: "Валюта счета",
          .details: "Детали операции (назначение платежа)", .card: "Номер карты",
        ],
        amountStyle: .splitIncomeExpense, descriptionFields: [.details],
        pendingMarkers: ["в обработке"])),
    descriptionRules: [
      rule(
        "raif-sbp-out",
        #"^Телефон получателя\s+(\+?\d{10,15})(?:\s+Сообщение(?:\s+(?!Идентификатор операции)(.*?))?)?(?:\s+Идентификатор операции СБП\s+\S+)?\s+Банк получателя\s+(.+)$"#,
        .sbpTransferOut, ["phone", "message", "bank"]),
      rule(
        "raif-person-out", #"^Перевели:\s*(.+?)\s+Перевод средств"#, .personTransferOut, ["name"]),
      rule(
        "raif-cashback",
        #"^(?:Кэшбэк|Кешбэк)\s+(?:за\s+(\p{L}+)|от\s+(.+?)(?:\s+На счет:.*)?$)"#,
        .cashbackPayout, ["month", "merchant"], direction: .income),
      rule(
        "raif-incoming-named", #"^Пришел перевод:\s*(.+?)\s*$"#, .personTransferIn, ["name"],
        direction: .income),
      rule(
        "raif-own-out", #"^Рублевый перевод между счетами"#, .ownContractTransferOut,
        direction: .expense),
      rule(
        "raif-own-in", #"^Рублевый перевод между счетами"#, .ownContractTransferIn,
        direction: .income),
      rule("raif-refund", #"^Возврат от\s+(.+)$"#, .purchaseRefund, ["merchant"]),
      rule(
        "raif-gph", #"Вознагр\.?\s*по\s+дог\.?\s*ГПХ"#, .contractIncome),
      rule(
        "raif-deposit-interest", #"^(?:Выплата процентов|Проценты по вкладу|Проценты на остаток)"#,
        .depositInterest, direction: .income),
      rule("raif-mobile", #"^Провайдер услуг"#, .mobileTopUp, direction: .expense),
      rule(
        "raif-service", #"^(.+?)\s+Со счета:"#, .servicePayment, ["merchant"], direction: .expense),
      rule(
        "raif-person-in",
        // Case-sensitive on purpose: a name is told from a message by its capital letters.
        // «Имя Отчество Ф», «Имя Отчество Фамилия» or «Имя Ф».
        "^((?-i:\(person)\\s+\(person)\\s+\\p{Lu}\\p{Ll}*|\(person)\\s+\\p{Lu})\\.?)(?:\\s+(.*?))?\\s+На счет:",
        .personTransferIn, ["name", "message"], direction: .income),
      rule(
        "raif-unnamed-in", #"^(Т-Банк|Сбербанк|Альфа-Банк|ВТБ|Перевели по номеру карты)$"#,
        .unnamedTransferIn, ["bank"], direction: .income, card: .present),
      rule(
        "raif-raw-card",
        #"^CARD\s+\*+\d+\s+\d{1,2}[A-Z]{3}\s+[A-Z]{3}\s+[\d.,]+\s+(.+)$"#, .rawCardLine,
        ["merchant"]),
      rule(
        "raif-purchase", #"^(.+)$"#, .purchase, ["merchant"], direction: .expense, card: .present),
      rule(
        "raif-card-credit", #"^(.+)$"#, .cardCredit, ["merchant"], direction: .income,
        card: .present),
    ])

  /// T-Bank «account turnover certificate», read from its text layer.
  public static let tbankPDF = StatementProfile(
    id: "tbank-pdf-v1", bankName: "Т-Банк", fileNamesTheBank: true,
    layout: .pdfText(
      StatementPDFTextLayout(
        signatureFragments: ["СПРАВКА О ДВИЖЕНИИ СРЕДСТВ", "ТБАНК"],
        rowPattern:
          #"^(\d{2}\.\d{2}\.\d{4})\s+(\d{2}\.\d{2}\.\d{4})\s+([+\-−–][\d\s  ]*[.,]\d{2})\s*(₽|\$|€)?\s+([+\-−–][\d\s  ]*[.,]\d{2})\s*(₽|\$|€)?\s+(.*?)\s+(\d{4}|—)\s*$"#,
        timePattern: #"^(\d{2}:\d{2})\s+(\d{2}:\d{2})(?:\s+(.*))?$"#,
        skipPatterns: [
          #"АО\s*«ТБанк»"#, #"БИК\s*\d"#, #"ИНН\s*\d"#, #"^\s*\d{1,3}\s*$"#, #"^Дата и время"#,
          #"^операции\s+списания"#, #"^Руководитель"#, #"^С уважением"#, #"^Пополнения:"#,
          #"^Расходы:"#, #"^Сумма в валюте"#, #"^Описание операции"#,
        ],
        contractPattern: #"Номер договора:\s*(\d+)"#,
        accountPattern: #"Номер лицевого сч[её]та:\s*(\d+)"#,
        openedPattern: #"Дата заключения договора:\s*(\d{2}\.\d{2}\.\d{4})"#,
        periodPattern: #"за период с\s*(\d{2}\.\d{2}\.\d{4})\s*по\s*(\d{2}\.\d{2}\.\d{4})"#,
        footerIncomePattern: #"Пополнения:\s*([\d\s  ]+[.,]\d{2})"#,
        footerExpensePattern: #"Расходы:\s*([\d\s  ]+[.,]\d{2})"#)),
    descriptionRules: [
      rule(
        "tb-internal-contract", #"^Внутренний перевод на договор\s+(\d+)"#, .ownContractTransferOut,
        ["contract"]),
      rule("tb-self-in", #"^Перевод себе"#, .ownContractTransferIn, direction: .income),
      rule(
        "tb-internal-from", #"^Внутрибанковский перевод с договора\s+(\d+)"#,
        .ownContractTransferIn, ["contract"], direction: .income),
      rule(
        "tb-card-internal",
        #"^Внутренний перевод на карту\s+(\d{4}\s+\d{2}\*+\s+\*+\s+\d{4})"#, .cardTransferOut,
        ["cardMask"]),
      rule(
        "tb-phone-out", #"^Внешний перевод по номеру телефона\s+(\+?\d{10,15})"#, .sbpTransferOut,
        ["phone"]),
      rule(
        "tb-sbp-in", #"^Пополнение\. Система быстрых платежей"#, .sbpTransferIn, direction: .income),
      rule("tb-card-out", #"^Перевод на карту другого банка"#, .cardTransferOut),
      rule("tb-transfer-fee", #"^Комиссия за перевод"#, .transferFee),
      rule("tb-fee", #"^Комиссия"#, .bankFee),
      rule("tb-savings-in", #"^Пополнение Кубышки"#, .savingsDeposit),
      rule("tb-savings-out", #"^Перевод средств из Кубышки"#, .savingsWithdrawal),
      rule("tb-notice-fee", #"^Плата за "#, .bankFee),
      rule("tb-credit-interest", #"^Проценты по кредиту"#, .bankInterestCharge),
      rule("tb-cashback", #"^Кэшбэк за"#, .cashbackPayout, direction: .income),
      rule("tb-compensation", #"^Компенсация покупки"#, .cashbackCompensation, direction: .income),
      rule("tb-cancel", #"^Отмена операции оплаты\s+(.+)$"#, .purchaseRefund, ["merchant"]),
      rule(
        "tb-refund", #"^Возврат средств по операции оплаты\s+(.+)$"#, .purchaseRefund, ["merchant"]),
      rule("tb-loan-in", #"^Получение займа"#, .loanProceeds),
      rule("tb-loan-out", #"^(?:Досрочное )?[Пп]огашение займа"#, .loanRepayment),
      rule(
        "tb-deposit-interest", #"^(?:Выплата процентов|Проценты на остаток)"#, .depositInterest,
        direction: .income),
      rule("tb-cash-in", #"^Внесение наличных"#, .cashDeposit),
      rule("tb-service", #"^Оплата услуг\s+(.+)$"#, .servicePayment, ["merchant"]),
      rule("tb-purchase", #"^Оплата в\s+(.+)$"#, .purchase, ["merchant"]),
      // A card line the bank prints with the place alone, no wording in front of it: a
      // description without any Cyrillic letter, so a Russian wording the rules do not know
      // is never taken for a purchase.
      rule("tb-card-purchase", #"^([^А-Яа-яЁё]+)$"#, .purchase, ["merchant"], direction: .expense, card: .present),
      rule("tb-card-credit", #"^([^А-Яа-яЁё]+)$"#, .cardCredit, ["merchant"], direction: .income, card: .present),
    ])

  private static func rule(
    _ id: String, _ pattern: String, _ kind: StatementOperationKind, _ groups: [String] = [],
    direction: StatementDescriptionRule.Direction = .any,
    card: StatementDescriptionRule.CardCondition = .any
  ) -> StatementDescriptionRule {
    StatementDescriptionRule(
      id: id, pattern: pattern, kind: kind, direction: direction, card: card, groups: groups)
  }
}
