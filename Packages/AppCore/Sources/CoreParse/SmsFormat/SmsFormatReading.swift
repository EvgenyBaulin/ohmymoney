import CoreKit
import Foundation

/// What a format read out of a text. `money` is empty for an information-only format (and for
/// one whose amount came out as zero): nothing is written for it.
public struct SmsFormatReading: Hashable, Sendable {
  public var formatId: String
  public var bank: BankBrand
  public var operation: BankOperation?
  /// What moved, above zero. The operation's own currency when the text gives it.
  public var money: Money?
  public var fee: Money?
  public var cashback: Money?
  public var balance: Money?
  public var availableBalance: Money?
  public var merchant: String?
  public var comment: String?
  public var day: DateOnly?
  public var time: TimeOfDay?
  public var mcc: Int?
  public var syncid: String?
  public var cardLast4: String?
  public var isAccountDigits = false

  public init(formatId: String, bank: BankBrand) {
    self.formatId = formatId
    self.bank = bank
  }

  /// Nothing to write: the text only informs.
  public var isInformational: Bool { money == nil || operation == nil }

  /// The operation as the rest of the entry flow knows it; nil for a text that only informs.
  public func message(source: String) -> BankMessage? {
    guard let operation, let money else { return nil }
    var message = BankMessage(
      bank: bank, operation: operation, money: money, merchant: merchant, cardLast4: cardLast4,
      isAccountDigits: isAccountDigits, balance: balance, time: time, day: day,
      source: source.trimmingCharacters(in: .whitespacesAndNewlines))
    message.fee = fee
    message.cashback = cashback
    message.availableBalance = availableBalance
    message.mcc = mcc
    message.syncid = syncid
    message.comment = comment
    message.formatId = formatId
    return message
  }
}

/// A format with its expression compiled once; the library keeps these.
public final class SmsCompiledFormat: @unchecked Sendable {
  public let format: SmsFormat
  private let regex: NSRegularExpression

  /// `nil` when the expression is not a valid one.
  public init?(_ format: SmsFormat) {
    guard let regex = try? NSRegularExpression(pattern: format.pattern) else { return nil }
    self.format = format
    self.regex = regex
  }

  public var groupCount: Int { regex.numberOfCaptureGroups }

  public func matches(_ text: String) -> Bool { firstMatch(text) != nil }

  private func firstMatch(_ text: String) -> NSTextCheckingResult? {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
  }

  /// Why the n-th group could not be read, or nil if all were.
  public struct Unreadable: Error, Hashable, Sendable { public var column: String }

  /// Reads a text; nil when the expression does not match.
  public func read(
    _ text: String, defaultCurrency: CurrencyCode = .rub, today: DateOnly? = nil
  ) -> Result<SmsFormatReading, Unreadable>? {
    guard let match = firstMatch(text) else { return nil }
    var groups: [(SmsColumn, String)] = []
    for (index, column) in format.columns.enumerated() where column != .skip {
      let range = match.range(at: index + 1)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
        continue
      }
      let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { groups.append((column, value)) }
    }
    return Self.reading(of: groups, format: format, defaultCurrency: defaultCurrency, today: today)
  }

  /// A place as a bank spells it, without the full stop that ends the sentence; the one that
  /// ends «Иван И.» stays.
  static func tidyPlace(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;-–—\"'«»"))
    if text.hasSuffix(".") {
      let words = text.split(separator: " ")
      let initial = words.count > 1 && words.last?.count == 2 && words.last?.first?.isUppercase == true
      if !initial { text.removeLast() }
    }
    return text
  }

  private static func reading(
    of groups: [(SmsColumn, String)], format: SmsFormat, defaultCurrency: CurrencyCode,
    today: DateOnly?
  ) -> Result<SmsFormatReading, Unreadable> {
    func value(_ column: SmsColumn) -> String? { groups.first { $0.0 == column }?.1 }
    var instrument = defaultCurrency
    if let text = value(.instrument) {
      guard let code = SmsFormatNumbers.currency(text) else {
        return .failure(Unreadable(column: SmsColumn.instrument.name))
      }
      instrument = code
    }
    var opInstrument = instrument
    if let text = value(.opInstrument) {
      guard let code = SmsFormatNumbers.currency(text) else {
        return .failure(Unreadable(column: SmsColumn.opInstrument.name))
      }
      opInstrument = code
    }
    var failed: Unreadable?
    func amount(_ column: SmsColumn, in currency: CurrencyCode) -> Money? {
      guard let text = value(column) else { return nil }
      guard let amount = SmsFormatNumbers.amount(text) else {
        failed = failed ?? Unreadable(column: column.name)
        return nil
      }
      return Money(amount: amount, currency: currency)
    }
    let outcome = amount(.outcome, in: instrument)
    let income = amount(.income, in: instrument)
    let opOutcome = amount(.opOutcome, in: opInstrument)
    let opIncome = amount(.opIncome, in: opInstrument)
    var fee = amount(.fee, in: instrument)
    var cashback = amount(.cashback, in: instrument)
    let balance = amount(.balance, in: instrument)
    let availableBalance = amount(.availableBalance, in: instrument)
    if let failed { return .failure(failed) }

    var reading = SmsFormatReading(formatId: format.id, bank: format.bank)
    reading.balance = balance
    reading.availableBalance = availableBalance
    reading.merchant = value(.payee).map(Self.tidyPlace).flatMap {
      BankMerchants.cleaned($0) ?? $0
    }
    reading.comment = value(.comment)
    reading.syncid = value(.syncid)

    if let text = value(.mcc) {
      guard let mcc = Int(text.filter(\.isNumber)), (0...9999).contains(mcc) else {
        return .failure(Unreadable(column: SmsColumn.mcc.name))
      }
      reading.mcc = mcc
    }
    for column in [SmsColumn.card, .account] {
      guard let text = value(column) else { continue }
      let digits = text.filter(\.isNumber)
      guard digits.count >= 4 else { return .failure(Unreadable(column: column.name)) }
      reading.cardLast4 = String(digits.suffix(4))
      reading.isAccountDigits = column == .account
    }
    if let text = value(.time) {
      guard let time = SmsFormatNumbers.clock(text) else {
        return .failure(Unreadable(column: SmsColumn.time.name))
      }
      reading.time = time
    }
    for (column, text) in groups {
      guard case .date(let pattern) = column else { continue }
      guard let parsed = SmsFormatNumbers.date(text, pattern: pattern, today: today) else {
        return .failure(Unreadable(column: column.name))
      }
      reading.day = parsed.day ?? reading.day
      reading.time = parsed.time ?? reading.time
    }

    // What moved: the operation's own figure first, else the account's.
    var moved = [opOutcome, opIncome, outcome, income].compactMap { $0 }.first
    var inferred: BankOperation? = (opOutcome ?? outcome) != nil ? .purchase : nil
    if inferred == nil, (opIncome ?? income) != nil { inferred = .income }
    // A fee or a cashback is the operation itself when nothing else moved.
    if moved == nil, let paid = fee {
      moved = paid
      fee = nil
      inferred = .fee
    } else if moved == nil, let came = cashback {
      moved = came
      cashback = nil
      inferred = .income
    }
    reading.fee = fee
    reading.cashback = cashback
    if let found = moved, found.amount > .zero {
      reading.money = found
      reading.operation = format.operation ?? inferred
    }
    if format.isInformational { reading.operation = nil }
    return .success(reading)
  }
}

extension SmsFormat {
  /// Reads a text with this format alone: nil when the expression does not match or is invalid.
  public func read(
    _ text: String, defaultCurrency: CurrencyCode = .rub, today: DateOnly? = nil
  ) -> Result<SmsFormatReading, SmsCompiledFormat.Unreadable>? {
    SmsCompiledFormat(self)?.read(text, defaultCurrency: defaultCurrency, today: today)
  }
}

/// Numbers, currencies, clocks and days as banks write them.
enum SmsFormatNumbers {
  /// «1 250,50», «1,250.50», «−450», «450.5»: the magnitude. A single separator is a decimal
  /// one; of two kinds the last one is.
  static func amount(_ raw: String) -> AmountE4? {
    var text = raw.filter { !$0.isWhitespace && $0 != "\u{202F}" }
    while let first = text.first, "+-−–".contains(first) || !first.isNumber && first != "." && first != "," {
      text.removeFirst()
    }
    while let last = text.last, !last.isNumber { text.removeLast() }
    guard !text.isEmpty else { return nil }
    let marks = text.filter { $0 == "." || $0 == "," }
    var normal = text
    if let decimalMark = marks.last {
      // The same mark twice or more is grouping («1.250.000»); a single one, or the last of two
      // kinds, is the decimal point.
      let grouping = marks.count > 1 && marks.allSatisfy { $0 == decimalMark }
      if grouping {
        normal = text.filter { $0 != decimalMark }
      } else {
        let cut = text.lastIndex(of: decimalMark) ?? text.endIndex
        let whole = text[..<cut].filter { $0 != "." && $0 != "," }
        normal = whole + "." + text[text.index(after: cut)...]
      }
    }
    guard normal.allSatisfy({ $0.isNumber || $0 == "." }), let decimal = Decimal(string: normal)
    else { return nil }
    guard let amount = try? AmountE4(decimal: decimal), amount <= AmountE4.inputLimit else {
      return nil
    }
    return amount
  }

  static func currency(_ raw: String) -> CurrencyCode? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let symbols: [String: String] = [
      "₽": "RUB", "$": "USD", "€": "EUR", "£": "GBP", "₸": "KZT", "₾": "GEL", "₺": "TRY",
      "р": "RUB", "р.": "RUB", "руб": "RUB", "руб.": "RUB", "rur": "RUB",
    ]
    if let code = symbols[text.lowercased()] ?? symbols[text] { return CurrencyCode(code) }
    guard text.count == 3, text.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
    return CurrencyCode(text)
  }

  static func clock(_ raw: String) -> TimeOfDay? {
    let parts = raw.split(separator: ":").map { Int($0) }
    guard parts.count >= 2, let hour = parts[0], let minute = parts[1], (0...23).contains(hour),
      (0...59).contains(minute)
    else { return nil }
    return TimeOfDay(hour: hour, minute: minute)
  }

  private static let patternLetters: Set<Character> = ["y", "M", "d", "H", "m", "s"]

  /// Whether `pattern` only uses `yyyy yy MM dd HH mm ss` and punctuation.
  static func isValidDatePattern(_ pattern: String) -> Bool {
    var tokens = 0
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      if character.isLetter {
        guard patternLetters.contains(character) else { return false }
        var end = index
        while end < pattern.endIndex, pattern[end] == character { end = pattern.index(after: end) }
        let length = pattern.distance(from: index, to: end)
        switch character {
        case "y": guard length == 2 || length == 4 else { return false }
        default: guard length == 2 else { return false }
        }
        tokens += 1
        index = end
      } else {
        index = pattern.index(after: index)
      }
    }
    return tokens > 0
  }

  /// A day and a clock time read by `pattern`; a pattern with no year takes the year of `today`
  /// (no day without it). nil when the text does not fit.
  static func date(
    _ raw: String, pattern: String, today: DateOnly?
  ) -> (day: DateOnly?, time: TimeOfDay?)? {
    guard isValidDatePattern(pattern) else { return nil }
    let text = Array(raw)
    var cursor = 0
    var year: Int?
    var month: Int?
    var day: Int?
    var hour: Int?
    var minute: Int?
    let chars = Array(pattern)
    var index = 0
    while index < chars.count {
      let character = chars[index]
      guard character.isLetter else {
        guard cursor < text.count, text[cursor] == character else { return nil }
        cursor += 1
        index += 1
        continue
      }
      var length = 0
      while index + length < chars.count, chars[index + length] == character { length += 1 }
      guard cursor + length <= text.count,
        let number = Int(String(text[cursor..<(cursor + length)])),
        text[cursor..<(cursor + length)].allSatisfy(\.isNumber)
      else { return nil }
      cursor += length
      index += length
      switch character {
      case "y": year = length == 2 ? 2000 + number : number
      case "M": month = number
      case "d": day = number
      case "H": hour = number
      case "m": minute = number
      default: break
      }
    }
    var result: (day: DateOnly?, time: TimeOfDay?) = (nil, nil)
    if let hour, let minute {
      guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
      result.time = TimeOfDay(hour: hour, minute: minute)
    }
    if let month, let day {
      guard (1...12).contains(month), (1...31).contains(day) else { return nil }
      if let resolved = year ?? today?.year {
        result.day = DateOnly(year: resolved, month: month, day: day)
      }
    }
    return result
  }
}
