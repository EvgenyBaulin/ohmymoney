import CoreKit
import Foundation

/// A half-open range of characters of the text being read.
struct ScanSpan: Hashable {
  var start: Int
  var end: Int
}

/// What a label in front of an amount says it is.
enum MoneyLabel: Hashable {
  case balance
  /// «Сумма», "Amount": the amount itself, the label is only noise to drop.
  case amount
  /// A commission, a cashback, a limit: money that is not the amount of the operation.
  case secondary
}

struct MoneyHit {
  var span: ScanSpan
  var money: Money
  /// The sign glued to the number: «−1 250,00 ₽».
  var sign: Character?
  var label: MoneyLabel?
  var labelSpan: ScanSpan?
}

struct CardHit {
  var span: ScanSpan
  var last4: String
  /// «СЧЁТ3230»: the last digits of an account, not of a card.
  var isAccount: Bool
}

struct TimeHit {
  var span: ScanSpan
  var time: TimeOfDay
}

/// The pieces of a bank text found by a plain scan, without any regular expression: money (a
/// number glued to a currency), the last four digits of a card, the time of day. The scan is
/// written by hand like the entry line's own, so it behaves the same on every platform.
struct BankScan {
  let chars: [Character]
  /// `chars` in lower case with «ё» as «е», position for position.
  let low: [Character]
  var count: Int { chars.count }

  init(_ text: String) {
    var chars: [Character] = []
    chars.reserveCapacity(text.count)
    for character in text {
      switch character {
      case "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}", "\t": chars.append(" ")
      case "\r\n", "\r": chars.append("\n")
      default: chars.append(character)
      }
    }
    self.chars = chars
    self.low = chars.map { character in
      let lowered = character.lowercased().first ?? character
      return lowered == "ё" ? "е" : lowered
    }
  }

  // MARK: - Characters

  func isDigit(_ index: Int) -> Bool {
    guard index >= 0, index < count else { return false }
    let character = chars[index]
    return character >= "0" && character <= "9"
  }

  func string(_ span: ScanSpan) -> String {
    String(chars[span.start..<span.end])
  }

  // MARK: - Currency

  private static let symbols: [Character: String] = [
    "₽": "RUB", "$": "USD", "€": "EUR", "£": "GBP", "₸": "KZT", "₾": "GEL", "₺": "TRY",
    "₴": "UAH", "֏": "AMD",
  ]

  private static let words: [String: String] = [
    "р": "RUB", "руб": "RUB", "рублей": "RUB", "рубля": "RUB", "rub": "RUB", "rur": "RUB",
    "usd": "USD", "eur": "EUR", "gbp": "GBP", "cny": "CNY", "kzt": "KZT", "тг": "KZT",
    "gel": "GEL", "try": "TRY", "aed": "AED", "amd": "AMD", "byn": "BYN", "uah": "UAH",
    "thb": "THB", "rsd": "RSD", "chf": "CHF", "jpy": "JPY", "kgs": "KGS", "uzs": "UZS",
  ]

  /// The currency written at `index` and where it ends, or nil.
  func currency(at index: Int) -> (code: String, end: Int)? {
    guard index >= 0, index < count else { return nil }
    if let code = Self.symbols[chars[index]] { return (code, index + 1) }
    guard chars[index].isLetter else { return nil }
    if index > 0, chars[index - 1].isLetter { return nil }
    var end = index
    while end < count, chars[end].isLetter, end - index < 8 { end += 1 }
    if end < count, chars[end].isLetter { return nil }
    guard let code = Self.words[String(low[index..<end])] else { return nil }
    return (code, end)
  }

  // MARK: - Numbers

  /// A number as a bank writes it — digits, a space between the thousands, a point or a comma
  /// before the fraction — starting at a digit; read by the rules of typed amounts.
  func number(at index: Int) -> (value: Decimal, end: Int)? {
    guard isDigit(index) else { return nil }
    var end = index
    while isDigit(end) { end += 1 }
    // A space groups thousands only after a group of one to three digits: «1 250», not «3230 450».
    let canGroup = end - index <= 3
    while canGroup, end < count, chars[end] == " ", isDigit(end + 1), isDigit(end + 2),
      isDigit(end + 3), !isDigit(end + 4)
    {
      end += 4
    }
    // «1,250.00», «1.234,56», «1 250,5»: groups of digits behind a point or a comma; the rules
    // of typed amounts say which separator means what, or that the number is none.
    while end + 1 < count, chars[end] == "." || chars[end] == ",", isDigit(end + 1) {
      end += 1
      while isDigit(end) { end += 1 }
    }
    let text = String(chars[index..<end])
    guard let value = TypedNumber.parse(text) else { return nil }
    return (value, end)
  }

  // MARK: - Money

  private static let balanceLabels = [
    "доступный остаток", "остаток по карте", "остаток на счете", "доступно", "остаток", "баланс",
    "available balance", "available", "balance", "ост", "на счете", "на счету",
  ]
  private static let amountLabels = ["сумма операции", "сумма", "amount", "sum"]
  private static let secondaryLabels = [
    "комиссия", "комиссии", "комиссией", "fee", "кэшбэк", "кешбэк", "кэшбек", "кешбек",
    "cashback", "бонус", "бонусы", "бонусов", "баллов", "лимит", "limit",
  ]

  /// The label standing right before `start`: «Баланс: », «Доступно », «Сумма ».
  func label(before start: Int) -> (MoneyLabel, ScanSpan)? {
    var end = start
    while end > 0, " :.=-–(".contains(low[end - 1]) { end -= 1 }
    guard end > 0 else { return nil }
    func suffix(of words: [String]) -> ScanSpan? {
      for word in words {
        let length = word.count
        guard end - length >= 0 else { continue }
        guard String(low[(end - length)..<end]) == word else { continue }
        if end - length > 0, low[end - length - 1].isLetter { continue }
        return ScanSpan(start: end - length, end: start)
      }
      return nil
    }
    if let span = suffix(of: Self.balanceLabels) { return (.balance, span) }
    if let span = suffix(of: Self.secondaryLabels) { return (.secondary, span) }
    if let span = suffix(of: Self.amountLabels) { return (.amount, span) }
    return nil
  }

  func moneyHits() -> [MoneyHit] {
    var hits: [MoneyHit] = []
    var index = 0
    while index < count {
      if isDigit(index) {
        let glued = index > 0 && chars[index - 1].isLetter
        if !glued, let (value, end) = number(at: index) {
          var cursor = end
          if cursor < count, chars[cursor] == " " { cursor += 1 }
          if let (code, currencyEnd) = currency(at: cursor),
            let money = makeMoney(value, code)
          {
            hits.append(hit(money: money, start: index, end: currencyEnd))
            index = currencyEnd
            continue
          }
        }
        while isDigit(index) { index += 1 }
        continue
      }
      if let (code, afterCurrency) = currency(at: index) {
        var cursor = afterCurrency
        if cursor < count, chars[cursor] == " " { cursor += 1 }
        if isDigit(cursor), let (value, end) = number(at: cursor),
          let money = makeMoney(value, code)
        {
          hits.append(hit(money: money, start: index, end: end))
          index = end
          continue
        }
      }
      index += 1
    }
    return hits
  }

  private func makeMoney(_ value: Decimal, _ code: String) -> Money? {
    guard let amount = try? AmountE4(decimal: value), amount <= AmountE4.inputLimit else {
      return nil
    }
    return Money(amount: amount, currency: CurrencyCode(code))
  }

  private func hit(money: Money, start: Int, end: Int) -> MoneyHit {
    var sign: Character?
    var from = start
    if start > 0, "+-−–—".contains(chars[start - 1]) {
      sign = chars[start - 1]
      from = start - 1
    }
    var result = MoneyHit(span: ScanSpan(start: from, end: end), money: money, sign: sign)
    if let (label, span) = label(before: from) {
      result.label = label
      result.labelSpan = span
    }
    return result
  }

  // MARK: - Cards

  private static let cardWords: Set<String> = [
    "mir", "мир", "visa", "mc", "mastercard", "maestro", "карта", "карты", "карте", "карту", "картой",
    "card", "cards",
  ]
  private static let accountWords: Set<String> = [
    "счет", "счета", "счету", "счетом", "account", "acct", "acc",
  ]

  func cardHits() -> [CardHit] {
    var hits: [CardHit] = []
    var index = 0
    while index < count {
      guard isDigit(index), !isDigit(index - 1) else {
        index += 1
        continue
      }
      var end = index
      while isDigit(end) { end += 1 }
      defer { index = end }
      guard end - index == 4 else { continue }
      // A bare four-digit number is an amount or a year; only a marker makes it a card.
      var cursor = index - 1
      var sawStar = false
      while cursor >= 0 {
        let character = chars[cursor]
        if " -№#:".contains(character) {
          cursor -= 1
        } else if "*•·".contains(character) {
          sawStar = true
          cursor -= 1
        } else if "xхXХ".contains(character), cursor == 0 || !chars[cursor - 1].isLetter {
          sawStar = true
          cursor -= 1
        } else {
          break
        }
      }
      var start = cursor + 1
      var account = false
      if cursor >= 0, chars[cursor].isLetter {
        var wordStart = cursor
        while wordStart > 0, chars[wordStart - 1].isLetter { wordStart -= 1 }
        let word = String(low[wordStart...cursor])
        if Self.cardWords.contains(word) {
          start = wordStart
        } else if Self.accountWords.contains(word) {
          start = wordStart
          account = true
        } else if !sawStar {
          continue
        }
      } else if !sawStar {
        continue
      }
      hits.append(
        CardHit(
          span: ScanSpan(start: start, end: end), last4: String(chars[index..<end]),
          isAccount: account))
    }
    return hits
  }

  // MARK: - Time

  func timeHits() -> [TimeHit] {
    var hits: [TimeHit] = []
    var index = 0
    while index < count {
      guard isDigit(index), !isDigit(index - 1) else {
        index += 1
        continue
      }
      var hourEnd = index
      while isDigit(hourEnd), hourEnd - index < 2 { hourEnd += 1 }
      guard !isDigit(hourEnd), hourEnd < count, chars[hourEnd] == ":", isDigit(hourEnd + 1),
        isDigit(hourEnd + 2), !isDigit(hourEnd + 3)
      else {
        while isDigit(index) { index += 1 }
        continue
      }
      let hour = Int(String(chars[index..<hourEnd])) ?? 99
      let minute = Int(String(chars[(hourEnd + 1)...(hourEnd + 2)])) ?? 99
      var end = hourEnd + 3
      if end + 2 < count, chars[end] == ":", isDigit(end + 1), isDigit(end + 2), !isDigit(end + 3) {
        end += 3
      }
      if hour <= 23, minute <= 59 {
        hits.append(
          TimeHit(
            span: ScanSpan(start: index, end: end), time: TimeOfDay(hour: hour, minute: minute)))
      }
      index = end
    }
    return hits
  }

  // MARK: - Words

  /// Where `phrase` stands in the lower-case text, at the start of a word. A short phrase
  /// ("pos", "atm") must be a whole word; a longer one is a stem («перевел» in «перевела»).
  func find(_ phrase: String) -> ScanSpan? {
    let target = Array(phrase)
    guard !target.isEmpty, target.count <= count else { return nil }
    var start = 0
    while start + target.count <= count {
      if low[start] == target[0], start == 0 || !low[start - 1].isLetter,
        Array(low[start..<(start + target.count)]) == target
      {
        let end = start + target.count
        if target.count > 4 || end == count || !low[end].isLetter {
          return ScanSpan(start: start, end: end)
        }
      }
      start += 1
    }
    return nil
  }
}
