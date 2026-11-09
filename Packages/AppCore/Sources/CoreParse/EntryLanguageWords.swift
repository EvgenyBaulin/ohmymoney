import CoreKit
import Foundation

/// A language's entry words, stored independently from parsing rules. Alternatives use `|`.
/// These provisional translations have not been reviewed by native speakers.
struct EntryLanguageWords: Sendable {
  let today: String
  let yesterday: String
  let dayBeforeYesterday: String
  let income: String
  let salary: String
  let expense: String
  let refund: String
  let reimbursement: String
  let transfer: String
  let debt: String
  let goal: String
  let from: String
  let to: String
  let thousand: String
  let currency: String
  let currencyCode: String

  init(
    _ today: String, _ yesterday: String, _ dayBeforeYesterday: String,
    _ income: String, _ salary: String, _ expense: String, _ refund: String,
    _ reimbursement: String, _ transfer: String, _ debt: String, _ goal: String,
    _ from: String, _ to: String, _ thousand: String, _ currency: String, _ currencyCode: String
  ) {
    self.today = today
    self.yesterday = yesterday
    self.dayBeforeYesterday = dayBeforeYesterday
    self.income = income
    self.salary = salary
    self.expense = expense
    self.refund = refund
    self.reimbursement = reimbursement
    self.transfer = transfer
    self.debt = debt
    self.goal = goal
    self.from = from
    self.to = to
    self.thousand = thousand
    self.currency = currency
    self.currencyCode = currencyCode
  }

  static func alternatives(_ text: String) -> [String] {
    text.split(separator: "|").map { TextNormalizer.normalized(String($0)) }
  }

  static let all: [StarterLanguage: EntryLanguageWords] = [
    .uk: .init(
      "сьогодні", "вчора|учора", "позавчора", "дохід", "зарплата", "витрата", "повернення",
      "повернення грошей", "переказ", "борг", "ціль", "з|із", "на|до", "тисяча|тисячі|тисяч",
      "гривня|гривні|гривень", "UAH"),
    .be: .init(
      "сёння", "учора", "пазаўчора", "даход", "зарплата", "выдатак", "вяртанне", "вяртанне грошай",
      "перавод", "доўг", "мэта", "з", "на|да", "тысяча|тысячы|тысяч", "рубель|рублі|рублёў", "BYN"),
    .kk: .init(
      "бүгін", "кеше", "алдыңғы күні", "кіріс", "жалақы", "шығыс", "қайтарым", "ақшаны қайтару",
      "аударым", "қарыз", "мақсат", "бастап", "дейін", "мың", "теңге", "KZT"),
    .uz: .init(
      "bugun", "kecha", "oʻtgan kuni|o'tgan kuni", "daromad", "maosh", "xarajat", "qaytarish",
      "pulni qaytarish", "oʻtkazma|o'tkazma", "qarz", "maqsad", "dan", "ga", "ming", "soʻm|so'm",
      "UZS"),
    .ky: .init(
      "бүгүн", "кечээ", "мурдагы күнү", "киреше", "айлык", "чыгаша", "кайтаруу", "акчаны кайтаруу",
      "которуу", "карыз", "максат", "тартып", "чейин", "миң", "сом", "KGS"),
    .tg: .init(
      "имрӯз", "дирӯз", "парерӯз", "даромад", "маош", "хароҷот", "баргардонӣ", "баргардонидани пул",
      "интиқол", "қарз", "ҳадаф", "аз", "ба", "ҳазор", "сомонӣ", "TJS"),
    .hy: .init(
      "այսօր", "երեկ", "երեկ չէ առաջին օրը", "եկամուտ", "աշխատավարձ", "ծախս", "վերադարձ",
      "գումարի վերադարձ", "փոխանցում", "պարտք", "նպատակ", "ից", "դեպի", "հազար", "դրամ", "AMD"),
    .ka: .init(
      "დღეს", "გუშინ", "გუშინწინ", "შემოსავალი", "ხელფასი", "ხარჯი", "დაბრუნება",
      "თანხის დაბრუნება", "გადარიცხვა", "ვალი", "მიზანი", "დან", "ზე", "ათასი", "ლარი", "GEL"),
    .az: .init(
      "bu gün", "dünən", "srağagün", "gəlir", "maaş", "xərc", "qaytarma", "pulun qaytarılması",
      "köçürmə", "borc", "məqsəd", "dan", "üçün", "min", "manat", "AZN"),
    .de: .init(
      "heute", "gestern", "vorgestern", "einkommen", "gehalt|lohn", "ausgabe", "erstattung",
      "rückzahlung", "überweisung|überweisen", "schuld|kredit", "ziel", "von", "nach|auf",
      "tausend", "euro", "EUR"),
    .fr: .init(
      "aujourd'hui|aujourd’hui", "hier", "avant-hier", "revenu", "salaire", "dépense",
      "remboursement", "remboursement de dette", "virement", "dette", "objectif", "de|depuis",
      "vers", "mille", "euro|euros", "EUR"),
    .es: .init(
      "hoy", "ayer", "anteayer", "ingreso", "sueldo|salario", "gasto", "reembolso",
      "devolución de deuda", "transferencia", "deuda", "meta", "de|desde", "a|hacia", "mil",
      "euro|euros", "EUR"),
    .it: .init(
      "oggi", "ieri", "l'altro ieri|l’altro ieri", "entrata|reddito", "stipendio", "spesa",
      "rimborso", "rimborso del debito", "bonifico", "debito", "obiettivo", "da", "a", "mille|mila",
      "euro", "EUR"),
    .portuguesePortugal: .init(
      "hoje", "ontem", "anteontem", "rendimento|receita", "salário", "despesa", "reembolso",
      "pagamento de dívida", "transferência", "dívida", "objetivo", "de", "para", "mil",
      "euro|euros", "EUR"),
    .pl: .init(
      "dzisiaj|dziś", "wczoraj", "przedwczoraj", "dochód", "wynagrodzenie|pensja", "wydatek",
      "zwrot", "zwrot długu", "przelew", "dług", "cel", "z", "na|do", "tysiąc|tysiące|tysięcy",
      "złoty|złote|złotych|zł", "PLN"),
    .cs: .init(
      "dnes", "včera", "předevčírem", "příjem", "mzda|výplata", "výdaj", "vrácení",
      "splacení dluhu", "převod", "dluh", "cíl", "z", "na|do", "tisíc", "koruna|koruny|korun|kč",
      "CZK"),
    .nl: .init(
      "vandaag", "gisteren", "eergisteren", "inkomen", "salaris|loon", "uitgave", "terugbetaling",
      "schuldaflossing", "overschrijving", "schuld", "doel", "van", "naar", "duizend", "euro", "EUR"
    ),
    .tr: .init(
      "bugün", "dün", "evvelsi gün", "gelir", "maaş", "gider", "iade", "borç iadesi",
      "havale|transfer", "borç", "hedef", "den", "için", "bin", "lira|lirası", "TRY"),
    .chineseSimplified: .init(
      "今天", "昨天", "前天", "收入", "工资", "支出", "退款", "还款", "转账", "债务", "目标", "从", "到", "千", "元|人民币",
      "CNY"),
    .chineseTraditional: .init(
      "今天", "昨天", "前天", "收入", "薪資", "支出", "退款", "還款", "轉帳", "債務", "目標", "從", "到", "千", "元|新臺幣|新台幣",
      "TWD"),
    .ja: .init(
      "今日|きょう", "昨日|きのう", "一昨日|おととい", "収入", "給与|給料", "支出", "返金", "返済", "振込|振替", "借金", "目標", "から",
      "へ", "千", "円", "JPY"),
    .ko: .init(
      "오늘", "어제", "그제|그저께", "수입", "급여|월급", "지출", "환불", "상환", "이체|송금", "빚|대출", "목표", "에서", "으로", "천",
      "원", "KRW"),
    .vi: .init(
      "hôm nay", "hôm qua", "hôm kia", "thu nhập", "lương", "chi tiêu", "hoàn tiền", "trả nợ",
      "chuyển khoản", "nợ", "mục tiêu", "từ", "đến", "nghìn|ngàn", "đồng", "VND"),
    .id: .init(
      "hari ini", "kemarin", "kemarin lusa", "pendapatan", "gaji", "pengeluaran",
      "pengembalian dana", "pelunasan utang", "transfer", "utang|hutang", "tujuan", "dari", "ke",
      "ribu", "rupiah", "IDR"),
    .th: .init(
      "วันนี้", "เมื่อวาน", "เมื่อวานซืน", "รายได้", "เงินเดือน", "รายจ่าย", "คืนเงิน", "ชำระหนี้", "โอน", "หนี้",
      "เป้าหมาย", "จาก", "ไป", "พัน", "บาท", "THB"),
    .hi: .init(
      "आज", "कल|बीता कल", "परसों|बीता परसों", "आय", "वेतन", "खर्च", "धनवापसी", "कर्ज वापसी", "अंतरण|स्थानांतरण", "कर्ज|ऋण",
      "लक्ष्य", "से", "को", "हज़ार|हजार", "रुपया|रुपये", "INR"),
    .portugueseBrazil: .init(
      "hoje", "ontem", "anteontem", "renda|receita", "salário", "despesa", "reembolso",
      "pagamento de dívida", "transferência", "dívida", "meta", "de", "para", "mil", "real|reais",
      "BRL"),
    .ar: .init(
      "اليوم", "أمس|امس", "أول أمس", "دخل", "راتب", "مصروف", "استرداد", "سداد دين", "تحويل", "دين",
      "هدف", "من", "إلى|الى", "ألف|الف", "درهم", "AED"),
    .he: .init(
      "היום", "אתמול", "שלשום", "הכנסה", "משכורת", "הוצאה", "החזר", "החזר חוב", "העברה", "חוב",
      "יעד", "מ", "אל", "אלף", "שקל|שקלים", "ILS"),
  ]
}

/// The original bilingual vocabulary plus one selected language. Keeping other languages out
/// prevents translated words from changing existing bilingual notes.
struct EntryLexicon: Sendable {
  let language: StarterLanguage
  let localized: EntryLanguageWords?
  let kindPhrases: [Lexicon.Phrase<TransactionKind>]
  let datePhrases: [Lexicon.Phrase<Int>]
  let transferPhrases: [[String]]
  let transferFromMarkers: Set<String>
  let transferToMarkers: Set<String>
  let currencyWords: [String: String]

  init(language: StarterLanguage) {
    self.language = language
    let words = EntryLanguageWords.all[language]
    localized = words
    var kinds = Lexicon.kindPhrases
    var dates = Lexicon.datePhrases
    if let words {
      for (text, kind) in [
        (words.income, TransactionKind.income), (words.salary, .income),
        (words.expense, .expense), (words.refund, .refund), (words.reimbursement, .reimbursement),
      ] {
        kinds += EntryLanguageWords.alternatives(text).map { Lexicon.Phrase($0, kind) }
      }
      for (text, offset) in [
        (words.today, 0), (words.yesterday, -1), (words.dayBeforeYesterday, -2),
      ] {
        dates += EntryLanguageWords.alternatives(text).map { Lexicon.Phrase($0, offset) }
      }
    }
    // A stable sort preserves the original tie order in the bilingual tables.
    kindPhrases = kinds.enumerated().sorted {
      $0.element.words.count == $1.element.words.count
        ? $0.offset < $1.offset : $0.element.words.count > $1.element.words.count
    }.map(\.element)
    datePhrases = dates.enumerated().sorted {
      $0.element.words.count == $1.element.words.count
        ? $0.offset < $1.offset : $0.element.words.count > $1.element.words.count
    }.map(\.element)
    let localTransfers = words.map { EntryLanguageWords.alternatives($0.transfer) } ?? []
    transferPhrases =
      (Lexicon.transferWords.sorted().map { [$0] }
      + localTransfers.map { $0.split(separator: " ").map(String.init) })
      .sorted { $0.count > $1.count }
    transferFromMarkers = Lexicon.transferFromMarkers.union(
      words.map { EntryLanguageWords.alternatives($0.from) } ?? [])
    transferToMarkers = Lexicon.transferToMarkers.union(
      words.map { EntryLanguageWords.alternatives($0.to) } ?? [])
    var currencies = Lexicon.currencyWords
    if let words {
      for word in EntryLanguageWords.alternatives(words.currency) {
        currencies[word] = words.currencyCode
      }
      currencies[words.currencyCode.lowercased()] = words.currencyCode
    }
    currencyWords = currencies
  }

  var debtPhrases: [[String]] { phrases(localized?.debt) }
  var goalPhrases: [[String]] { phrases(localized?.goal) }

  private func phrases(_ text: String?) -> [[String]] {
    guard let text else { return [] }
    return EntryLanguageWords.alternatives(text).map { $0.split(separator: " ").map(String.init) }
  }

  /// Decimal digits used by Arabic, Hindi, Thai and full-width keyboards. Mapping is limited
  /// to numeric text; names, notes, highlights and the original input keep their spelling.
  func amountText(_ text: String) -> String {
    guard localized != nil else { return text }
    var result = ""
    for character in text {
      if let digit = character.wholeNumberValue, (0...9).contains(digit), character.isNumber {
        result += String(digit)
      } else if character == "٫" {
        result += "."
      } else if character == "٬" {
        result += ","
      } else {
        result.append(character)
      }
    }
    for suffix in EntryLanguageWords.alternatives(localized?.thousand ?? "") {
      if result.lowercased().hasSuffix(suffix) {
        let number = String(result.dropLast(suffix.count))
        if !number.isEmpty, number.contains(where: ExpressionLexer.isDigit) {
          return number + "k"
        }
      }
    }
    return result
  }

  func isThousand(_ text: String) -> Bool {
    EntryLanguageWords.alternatives(localized?.thousand ?? "").contains(text)
  }
}
