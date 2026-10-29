import CoreKit
import Foundation

/// Russian half of the entry-line vocabulary. Every spelling is written the way the
/// normaliser produces it: lower case and "ё" already folded into "е".
extension Lexicon {
  static let russianKindPhrases: [Phrase<TransactionKind>] = [
    Phrase("возврат денег", .reimbursement),
    Phrase("возврат средств", .reimbursement),
    Phrase("вернули долг", .reimbursement),
    Phrase("возврат", .refund),
    Phrase("возврата", .refund),
    Phrase("вернул покупку", .refund),
    Phrase("доход", .income),
    Phrase("доходы", .income),
    Phrase("зарплата", .income),
    Phrase("зп", .income),
    Phrase("аванс", .income),
  ]

  /// «Аванс» is the advance on a salary — income — until «за» names a job it pays for:
  /// «аванс за ремонт» is a prepayment, an expense. A month behind «за» is still the salary:
  /// «аванс за сентябрь», «аванс за этот месяц».
  static let russianAdvanceWords: Set<String> = ["аванс"]
  static let russianAdvanceMarker = "за"
  static let russianSalaryPeriods: Set<String> = [
    "январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь",
    "октябрь", "ноябрь", "декабрь", "месяц", "полмесяца",
  ]

  /// Offsets in days from "today".
  static let russianDatePhrases: [Phrase<Int>] = [
    Phrase("сегодня", 0),
    Phrase("вчера", -1),
    Phrase("позавчера", -2),
  ]

  /// Read anywhere in the line, so only in the dative the spec lists («девушке», «друзьям»,
  /// «семье»): whom the money went to. The nominative is the one doing something — «муж
  /// заправил машину» — and stays in the note.
  static let russianForWhomWords: [String: ForWhom] = [
    "себе": .me,
    "мне": .me,
    "девушке": .partner,
    "партнеру": .partner,
    "жене": .partner,
    "мужу": .partner,
    "парню": .partner,
    "другу": .friends,
    "друзьям": .friends,
    "семье": .family,
    "родителям": .family,
    "маме": .family,
    "папе": .family,
    "детям": .family,
  ]

  /// The same words in the case «для» asks for. Read only right after the marker, never in
  /// a blind scan of the line: «от мамы» is not «для мамы», «позвал друзей» is not «для
  /// друзей». Written out instead of matched by a stem, because a stem also matches names:
  /// «Жени» and «жены» share «жен».
  static let russianDeclinedForWhomWords: [String: ForWhom] = [
    "себя": .me,
    "друзей": .friends,
    "девушки": .partner,
    "партнера": .partner,
    "партнерши": .partner,
    "жены": .partner,
    "мужа": .partner,
    "парня": .partner,
    "друга": .friends,
    "семьи": .family,
    "родителей": .family,
    "мамы": .family,
    "папы": .family,
    "детей": .family,
  ]

  static let russianCurrencyWords: [String: String] = [
    "р": "RUB", "руб": "RUB", "рубль": "RUB", "рубля": "RUB", "рублей": "RUB",
    "рублях": "RUB", "рубли": "RUB",
    "доллар": "USD", "доллара": "USD", "долларов": "USD", "долларах": "USD",
    "бакс": "USD", "баксов": "USD",
    "евро": "EUR",
    "тенге": "KZT",
    "юань": "CNY", "юаня": "CNY", "юаней": "CNY",
    "лира": "TRY", "лиры": "TRY", "лир": "TRY",
    "дирхам": "AED", "дирхама": "AED", "дирхамов": "AED",
    "лари": "GEL",
    "драм": "AMD", "драма": "AMD", "драмов": "AMD",
    "бат": "THB", "бата": "THB", "батов": "THB",
  ]

  /// Currency names that are everyday Russian words as well — «драма» and its «драм», the lyre
  /// «лира» with «лиры» and «лир»: a currency only right after a number («900 драм», «80 лир»)
  /// or glued to it; «кино драма 500» is a film.
  static let russianWordlikeCurrencyNames: Set<String> = ["драма", "драм", "лира", "лиры", "лир"]

  /// Possessives that stand between a marker and the word it introduces: «для моей мамы»,
  /// «в нашей столовой». Every case of «мой», «твой», «свой», «наш», «ваш», and «его», «её»,
  /// «их», which do not decline.
  static let russianDeterminers: Set<String> = [
    "мой", "моя", "мое", "мои", "моего", "моей", "моему", "моим", "моих", "мою", "моими",
    "твой", "твоя", "твое", "твои", "твоего", "твоей", "твоему", "твоим", "твоих", "твою",
    "твоими",
    "свой", "своя", "свое", "свои", "своего", "своей", "своему", "своим", "своих", "свою",
    "своими",
    "наш", "наша", "наше", "наши", "нашего", "нашей", "нашему", "нашим", "наших", "нашу",
    "нашими",
    "ваш", "ваша", "ваше", "ваши", "вашего", "вашей", "вашему", "вашим", "ваших", "вашу",
    "вашими",
    "его", "ее", "их",
    "этот", "эта", "это", "эти", "этого", "этой", "этому", "этим", "этих", "эту", "этими",
  ]

  /// When, not where: a weekday, a month or a time of day behind «в» / «во» is not a place
  /// («в среду», «в январе», «в обед»). It stays in the note; the spec's dates are only the
  /// keywords and «12.09».
  static let russianTimeWords: Set<String> = [
    "понедельник", "вторник", "среда", "среду", "четверг", "пятница", "пятницу", "суббота",
    "субботу", "воскресенье", "выходные", "выходной",
    "январе", "феврале", "марте", "апреле", "мае", "июне", "июле", "августе", "сентябре",
    "октябре", "ноябре", "декабре",
    "обед", "полдень", "полночь", "ночь",
  ]

  /// Words that make the number in front of them a count or a day, not money: «2 шт»,
  /// «1,5 кг», «3 ночи», «8 марта».
  static let russianWordsAfterACount: Set<String> = [
    "шт", "штук", "штуки", "штука", "уп", "упак", "упаковки", "упаковок", "пачки", "пачек",
    "бутылки", "бутылок", "кг", "г", "гр", "грамм", "граммов", "л", "литр", "литра", "литров",
    "мл",
    "час", "часа", "часов", "мин", "минут", "минуты", "дня", "дней", "ночи", "ночей", "недели",
    "недель", "месяца", "месяцев",
    "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября",
    "октября", "ноября", "декабря",
  ]

  static let russianPersonMarkers: Set<String> = ["для"]
  /// Whom money back came from: «возврат денег 1700 от Ани». Only money back reads it; in any
  /// other line «от» stays in the note («торт от Ани» is a cake, not a person's money).
  static let russianFromMarkers: Set<String> = ["от"]
  static let russianPlaceMarkers: Set<String> = ["в", "во"]
  /// The cashback the bank gave for the purchase, in every spelling people type: «кэшбэк»,
  /// «скидка 300»: the money the price fell by.
  static let russianDiscountWords: Set<String> = ["скидка", "скидку", "скидки", "скидкой"]
  /// «кэшбек», «кешбэк», «кешбек» (and «ё» folds into «е»).
  static let russianCashbackWords: Set<String> = [
    "кэшбэк", "кэшбек", "кешбэк", "кешбек", "кэшбэка", "кэшбека", "кешбэка", "кешбека",
    "кэшбэком", "кэшбеком", "кешбэком", "кешбеком",
  ]
  /// «кэшбек 7 процентов».
  static let russianPercentWords: Set<String> = ["процент", "процента", "процентов", "проц"]
  /// «в 18:09»: the word in front of a time goes with it.
  static let russianTimeMarkers: Set<String> = ["в", "во"]
  /// A transfer between accounts: «перевод 5000 сбер т-банк», «перевёл со сбера на т-банк».
  static let russianTransferWords: Set<String> = [
    "перевод", "перевел", "перевела", "перевели", "перевести", "перевожу", "перекинул",
    "перекинула",
  ]
  /// «пополам с машей», «угостил машу», «за машу».
  static let russianHalfWords: Set<String> = ["пополам"]
  static let russianWithWords: Set<String> = ["с", "со"]
  static let russianGiftWords: Set<String> = [
    "угостил", "угостила", "угостили", "угощаю", "подарил", "подарила",
  ]
  static let russianPaidForMarkers: Set<String> = ["за"]
  /// The account the money leaves and the one it comes to.
  static let russianTransferFromMarkers: Set<String> = ["с", "со"]
  static let russianTransferToMarkers: Set<String> = ["на", "в", "во"]
  static let russianGoalMarkers: Set<String> = ["цель", "цели", "целей", "накопление"]
  /// «кофе 250 со счёта»: the money leaves the account itself, not its card. Normalised, so
  /// «счёта» and «счета» alike.
  static let russianWithoutCardPhrases: [[String]] = [
    ["со", "счета"], ["с", "счета"], ["со", "своего", "счета"], ["счетом"],
  ]
  /// «смз 15000»: income of the self-employed, from individuals.
  static let russianSelfEmployedWords: Set<String> = ["смз"]
  static let russianDebtMarkers: Set<String> = [
    "кредит", "кредиту", "кредита", "долг", "долгу", "долга", "займ", "займу", "ипотека",
  ]
  /// «гарантия 2г», «возврат 14д»: the word, then a count with its unit.
  static let russianWarrantyWords: Set<String> = ["гарантия", "гарантии", "гарантию"]
  static let russianReturnWords: Set<String> = ["возврат", "возврата"]
  static let russianTermPrepositions: Set<String> = ["на"]
  static let russianTermUnits: [String: TermReading.Unit] = [
    "д": .day, "дн": .day, "день": .day, "дня": .day, "дней": .day,
    "н": .week, "нед": .week, "неделя": .week, "недели": .week, "неделю": .week, "недель": .week,
    "м": .month, "мес": .month, "месяц": .month, "месяца": .month, "месяцев": .month,
    "г": .year, "год": .year, "года": .year, "лет": .year,
  ]
}
