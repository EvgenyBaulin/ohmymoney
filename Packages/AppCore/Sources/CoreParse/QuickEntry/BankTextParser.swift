import CoreKit
import Foundation

/// Reads the texts banks send — a push, an SMS, a letter — and the rows of a history copied
/// from a bank's app. One scan serves every bank (`BankScan`); the templates are the words
/// that tell the operation, in Russian and in English.
///
/// A text is a bank's only when it has all of: an operation word («Покупка», "Purchase"), an
/// amount with a currency, and a card, an account or a balance — what no sentence typed by hand
/// has. Anything else is not read: the paste is then an ordinary line of the entry field
/// (a text typed by hand is never taken for a bank's). The templates are part of the core and change with a
/// release; there is no report of unknown texts.
public struct BankTextParser: Sendable {
  public init() {}

  /// One text. `today` only matters for a day written as «вчера» or «12 октября».
  public func parse(_ text: String, today: DateOnly? = nil) -> BankMessage? {
    let scan = BankScan(text)
    guard scan.count > 0, scan.count <= Self.longestText else { return nil }
    return read(scan, source: text, today: today, strict: true)
  }

  /// How many pieces of words a bank text may have left once its parts are read: the shop,
  /// the bank's own name, the person.
  static let mostLeftoverPieces = 3

  /// A text longer than any push, SMS or letter of a shop is not one of a bank.
  static let longestText = 4_000

  // MARK: - Operation words

  private struct Phrase {
    var words: [String]
    var operation: BankOperation
  }

  /// In order of precedence: the first group with a word in the text tells the operation.
  private static let phrases: [Phrase] = [
    Phrase(
      words: [
        "возврат", "отмена покупки", "отмена оплаты", "refund", "reversal", "purchase return",
      ],
      operation: .refund),
    Phrase(
      words: [
        "выдача наличных", "снятие наличных", "снятие", "cash withdrawal", "withdrawal",
        "банкомат", "atm",
      ], operation: .cashWithdrawal),
    Phrase(
      words: ["зарплата", "заработная плата", "аванс", "salary"], operation: .income),
    Phrase(
      words: [
        "перевод от", "входящий перевод", "получен перевод", "поступление", "пополнение",
        "зачисление", "зачислен", "поступил", "credited", "received", "deposit", "top up",
        "top-up", "topup", "incoming transfer",
      ], operation: .transferIn),
    Phrase(
      words: [
        "перевод", "перевел", "отправлен", "исходящий", "transfer", "sent", "сбп",
      ], operation: .transferOut),
    Phrase(
      words: ["комиссия", "плата за обслуживание", "плата за", "fee", "commission"],
      operation: .fee),
    Phrase(
      words: [
        "покупка", "оплата", "оплачено", "списание", "платеж", "purchase", "payment", "debit",
        "spent", "pos", "расход",
      ], operation: .purchase),
    // A cashback or interest is money that came only when nothing else was done in the text:
    // «Покупка 1000 ₽. Кэшбэк 10 ₽» is a purchase.
    Phrase(
      words: [
        "кэшбэк", "кешбэк", "кэшбек", "кешбек", "cashback", "проценты", "начисление процентов",
        "interest",
      ], operation: .income),
  ]

  /// The operation and the spans of the words that told it (and of every other operation word,
  /// which are not part of a shop's name either).
  private func operation(in scan: BankScan) -> (BankOperation, [ScanSpan])? {
    var found: BankOperation?
    var spans: [ScanSpan] = []
    for group in Self.phrases {
      for word in group.words {
        if let span = scan.find(word) {
          spans.append(span)
          if found == nil { found = group.operation }
        }
      }
    }
    // «Иван И. перевёл(а) вам 3000р»: a transfer that came, not one that left.
    if found == .transferOut, scan.find("вам") != nil, scan.find("перевел") != nil {
      found = .transferIn
    }
    guard let found else { return nil }
    return (found, spans)
  }

  // MARK: - Reading

  private func read(
    _ scan: BankScan, source: String, today: DateOnly?, strict: Bool
  ) -> BankMessage? {
    let hits = scan.moneyHits()
    let cards = scan.cardHits()
    let times = scan.timeHits()
    let balance = hits.first(where: { $0.label == .balance })

    var found = operation(in: scan)
    if strict {
      guard found != nil else { return nil }
    } else if found == nil {
      // A row of a history: no card, no balance, but a signed amount.
      guard let signedHit = hits.first(where: { $0.sign != nil && $0.label == nil }) else {
        return nil
      }
      found = (signedHit.sign == "+" ? .income : .purchase, [])
    }
    guard let (operation, operationSpans) = found else { return nil }

    // The amount is the first money that is neither the balance nor a side figure; a text that
    // is about a commission or a cashback has only the side figure to offer.
    var amountHit = hits.first(where: { $0.label != .balance && $0.label != .secondary })
    if amountHit == nil, operation == .fee || operation == .income {
      amountHit = hits.first(where: { $0.label == .secondary })
    }
    guard let amount = amountHit, amount.money.amount > .zero else { return nil }
    // The part no sentence typed by hand has.
    if strict, cards.isEmpty, balance == nil { return nil }

    var taken = [Bool](repeating: false, count: scan.count)
    func take(_ span: ScanSpan) {
      for index in max(span.start, 0)..<min(span.end, scan.count) { taken[index] = true }
    }
    for hit in hits {
      take(hit.span)
      if let label = hit.labelSpan { take(label) }
    }
    cards.forEach { take($0.span) }
    times.forEach { take($0.span) }
    operationSpans.forEach(take)

    let date = BankDates.find(in: scan, taken: taken, today: today)
    if let date { take(date.span) }

    let (merchant, pieceCount) = merchantText(in: scan, taken: taken, after: amount.span.start)
    // A push has a shop or a person and little else; a text with a paragraph of words left
    // over is a message somebody wrote, with a push pasted into it.
    if strict, pieceCount > Self.mostLeftoverPieces { return nil }
    let card = cards.first
    return BankMessage(
      bank: brand(of: scan, hits: hits, cards: cards, times: times),
      operation: operation, money: amount.money, merchant: merchant,
      cardLast4: card?.last4, isAccountDigits: card?.isAccount ?? false,
      balance: balance?.money, time: times.first?.time, day: date?.day,
      source: source.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// A row of a history copied from a bank's app: «PYATEROCHKA −1 250,00 ₽ 12 октября».
  /// Needs a signed amount; what the rows of one list have in common is judged by the caller.
  func readHistoryRow(_ text: String, today: DateOnly?) -> BankMessage? {
    let scan = BankScan(text)
    guard scan.count > 0, scan.count <= Self.longestText else { return nil }
    return read(scan, source: text, today: today, strict: false)
  }

  // MARK: - Shop

  private static let separators: Set<Character> = [";", "|", "\n", "\u{1}"]
  private static let prepositions: Set<String> = [
    "в", "во", "на", "от", "из", "со", "с", "для", "at", "in", "to", "from", "for", "by",
  ]
  /// Names of banks: a bank that signs its own text is not the shop or the person in it.
  private static let bankNames: Set<String> = [
    "сбер", "сбербанк", "sber", "sberbank", "втб", "vtb", "vtbbank", "тбанк", "тинькофф",
    "тинькоффбанк", "tinkoff", "tinkoffbank", "райффайзен", "райффайзенбанк", "raiffeisen",
    "raiffeisenbank", "альфа", "альфабанк", "alfa", "alfabank", "банк", "bank",
  ]
  private static let noise: Set<String> = [
    "rub", "rur", "руб", "р", "usd", "eur", "карта", "счет", "магазин",
  ]

  /// What is left of the text when everything that was read is taken out: the shop, or the
  /// person for a transfer. Several pieces — a push puts the shop between full stops — give the
  /// first one after the amount, else the first.
  private func merchantText(
    in scan: BankScan, taken: [Bool], after amountStart: Int
  ) -> (name: String?, pieces: Int) {
    var pieces: [(start: Int, text: String)] = []
    var current = ""
    var start = 0
    func flush(keepingDot: Bool = false) {
      var text = Self.tidy(current)
      if keepingDot { text += "." }
      if text.contains(where: \.isLetter) { pieces.append((start, text)) }
      current = ""
    }
    for index in 0..<scan.count {
      let character = scan.chars[index]
      let stopsHere =
        taken[index] || Self.separators.contains(character)
        || (character == "." && (index + 1 == scan.count || scan.chars[index + 1] == " "))
      if stopsHere {
        // A full stop that ends «Иван И.» stays with the name.
        let initial =
          !taken[index] && character == "." && current.last?.isUppercase == true
          && current.dropLast().last == " "
        flush(keepingDot: initial)
        continue
      }
      if current.isEmpty { start = index }
      current.append(character)
    }
    flush()
    let usable = pieces.compactMap { piece -> (Int, String)? in
      guard let text = Self.withoutPreposition(piece.text) else { return nil }
      return (piece.start, text)
    }
    let chosen = usable.first(where: { $0.0 > amountStart }) ?? usable.first
    guard let raw = chosen?.1 else { return (nil, usable.count) }
    return (BankMerchants.cleaned(raw), usable.count)
  }

  private static func tidy(_ text: String) -> String {
    let edges = CharacterSet(charactersIn: " ,.:-–—()\"'«»•·*")
    var value = text.trimmingCharacters(in: edges)
    while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
    return value
  }

  private static func withoutPreposition(_ text: String) -> String? {
    var words = text.split(separator: " ").map(String.init)
    while let first = words.first, prepositions.contains(first.lowercased()) { words.removeFirst() }
    while let first = words.first, noise.contains(first.lowercased()), words.count > 1 {
      words.removeFirst()
    }
    let joined = words.joined(separator: " ")
    guard joined.contains(where: \.isLetter), !noise.contains(joined.lowercased()),
      !bankNames.contains(BankMerchants.squeezed(joined))
    else { return nil }
    return joined
  }

  // MARK: - Bank

  private func brand(
    of scan: BankScan, hits: [MoneyHit], cards: [CardHit], times: [TimeHit]
  ) -> BankBrand {
    let named: [(BankBrand, [String])] = [
      (.sber, ["сбер", "sber"]),
      (.tbank, ["т-банк", "тбанк", "тинькофф", "tinkoff", "t-bank"]),
      (.vtb, ["втб", "vtb"]),
      (.raiffeisen, ["райффайзен", "raiffeisen", "raiff"]),
      (.alfa, ["альфа", "alfa"]),
    ]
    for (brand, names) in named where names.contains(where: { scan.find($0) != nil }) {
      return brand
    }
    // Sber: «MIR-3230 12:45 Покупка 1250р …» — the card and the time first, rubles as «р».
    if let card = cards.first, card.span.start <= 1,
      let time = times.first, time.span.start - card.span.end <= 2
    {
      return .sber
    }
    if let first = hits.first, scan.chars[first.span.end - 1] == "р",
      first.span.end - 2 >= 0, scan.isDigit(first.span.end - 2)
    {
      return .sber
    }
    // T-Bank: the operation, a comma, then the card or the account: «Покупка, карта *3230. …»
    if let comma = scan.chars.firstIndex(of: ","),
      let word = scan.find("карта") ?? scan.find("счет") ?? scan.find("счёт"),
      word.start == comma + 2, hits.contains(where: { scan.chars[$0.span.end - 1] == "₽" })
    {
      return .tbank
    }
    // VTB: the card leads the text: «Карта *3230: Покупка 1250.00 RUR, …»
    if let card = cards.first, card.span.start == 0 { return .vtb }
    if scan.find("сумма") != nil || scan.find("amount") != nil { return .raiffeisen }
    if hits.contains(where: { hit in
      hit.span.end >= 3 && String(scan.low[(hit.span.end - 3)..<hit.span.end]) == "rur"
    }) {
      return .alfa
    }
    return .unknown
  }
}
