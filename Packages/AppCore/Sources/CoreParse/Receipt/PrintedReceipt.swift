import CoreKit
import Foundation

/// What kind of paper a photo shows, as far as its printed words say.
public enum PaperKind: Hashable, Sendable {
  /// A Russian cash receipt with the drive, document and sign numbers printed on it.
  case fiscal
  /// The terminal's slip of a card payment: the sum and the moment of the payment, no receipt
  /// number.
  case slip
  /// A restaurant's guest bill: not a receipt, the payment is still to come.
  case bill
  /// Any other receipt (of another country, say): only its total and its moment are read.
  case other
}

/// A receipt read from the printed text of a photo (the recognised lines), not from its QR code.
public struct PrintedReceipt: Hashable, Sendable {
  public var kind: PaperKind
  /// The sum, the day, the minute and — for a fiscal receipt whose three numbers all passed the
  /// checks — the numbers. Whatever the paper does not say is not made up.
  public var receipt: ReceiptQR
  /// The paper printed fiscal numbers but they did not pass the checks (a drive number is 16
  /// digits): the receipt is offered without them and is never taken for one already recorded.
  public var numbersRejected: Bool
  /// The shop's name, offered only for paper of another country read with confidence: the name
  /// stands in the header, and the recognition was sure of that line and of the text as a whole.
  /// `nil` otherwise: then only the total and the moment are proposed.
  public var merchant: String?

  public init(
    kind: PaperKind, receipt: ReceiptQR, numbersRejected: Bool, merchant: String? = nil
  ) {
    self.kind = kind
    self.receipt = receipt
    self.numbersRejected = numbersRejected
    self.merchant = merchant
  }
}

/// A line of recognised text with how sure the recognition was of it (0...1).
public struct RecognizedLine: Hashable, Sendable {
  public var text: String
  public var confidence: Float

  public init(text: String, confidence: Float) {
    self.text = text
    self.confidence = confidence
  }
}

/// The result of reading the lines of a photo.
public enum PrintedReading: Hashable, Sendable {
  case receipt(PrintedReceipt)
  /// A guest bill: nothing is read from it, the receipt or the slip comes after.
  case bill
  /// No total or no moment to be read.
  case nothing
}

/// Reads the text a camera recognised on a receipt, a slip or a bill. Pure text rules: where the
/// text comes from (Vision) is the app's business. Nothing here guesses a sum: a total is a
/// number on a line that says «total» in one of the languages known here, or on the next one.
public enum PrintedReceiptReader {
  public static func read(lines rawLines: [String]) -> PrintedReading {
    read(entries: rawLines.map { ($0, nil) })
  }

  /// Like `read(lines:)`, and a confidently read foreign receipt also gives the shop's name.
  public static func read(recognized: [RecognizedLine]) -> PrintedReading {
    read(entries: recognized.map { ($0.text, $0.confidence) })
  }

  private static func read(
    entries rawEntries: [(text: String, confidence: Float?)]
  )
    -> PrintedReading
  {
    let entries = rawEntries.map {
      (text: $0.text, folded: fold($0.text), confidence: $0.confidence)
    }
    .filter { !$0.folded.isEmpty }
    let lines = entries.map(\.folded)
    guard !lines.isEmpty else { return .nothing }
    let drive = fiscalValue(["фн"], in: lines)
    let document = fiscalValue(["фд"], in: lines)
    let sign = fiscalValue(["фпд", "фп"], in: lines)
    let namedNumbers = [drive, document, sign].compactMap { $0 }.count
    let kind: PaperKind
    if namedNumbers >= 2 || (namedNumbers >= 1 && lines.contains { $0.contains("кассовый чек") }) {
      kind = .fiscal
    } else if markers(slipMarkers, in: lines) >= 2 {
      kind = .slip
    } else if markers(billMarkers, in: lines) >= 1 {
      return .bill
    } else {
      kind = .other
    }
    guard let total = total(in: lines, kind: kind), let moment = moment(in: lines) else {
      return .nothing
    }
    var numbers: ReceiptNumbers?
    var rejected = false
    if kind == .fiscal {
      numbers = validNumbers(drive: drive, document: document, sign: sign)
      rejected = numbers == nil
    }
    let operation: ReceiptOperation =
      lines.contains { $0.contains("возврат прихода") }
      ? .saleReturn : lines.contains { $0.contains("возврат расхода") } ? .payoutReturn : .sale
    let receipt = ReceiptQR(
      day: moment.day, time: moment.time, second: moment.second, amountE4: total.amount,
      operation: operation, fiscalDrive: numbers?.fiscalDrive,
      documentNumber: numbers?.documentNumber, fiscalSign: numbers?.fiscalSign,
      currency: total.currency ?? currency(in: lines) ?? .rub)
    let merchant = kind == .other ? merchant(in: entries) : nil
    return .receipt(
      PrintedReceipt(kind: kind, receipt: receipt, numbersRejected: rejected, merchant: merchant))
  }

  // MARK: Shop

  /// Recognition at least this sure of a line, and of the text on average, may name the shop.
  static let merchantConfidence: Float = 0.8
  private static let headerLines = 5
  private static let notAName = [
    "receipt", "check", "cheque", "invoice", "tax", "vat", "fiscal", "cashier", "date", "time",
    "total", "subtotal", "thank", "thanks", "welcome", "tel", "phone", "чек", "кассовый",
    "касса", "кассир", "итог", "итого", "tarix", "vaxt", "cemi", "qebz", "voen",
  ]

  /// The first line of the header that reads like a name: mostly letters, no sums, no dates,
  /// none of the words a receipt prints about itself. Never guessed from dim text.
  private static func merchant(
    in entries: [(text: String, folded: String, confidence: Float?)]
  ) -> String? {
    let known = entries.compactMap(\.confidence)
    guard known.count == entries.count,
      known.reduce(0, +) / Float(known.count) >= merchantConfidence
    else { return nil }
    for entry in entries.prefix(headerLines) {
      let text = entry.text.trimmingCharacters(in: .whitespaces)
      let letters = text.filter(\.isLetter).count
      let visible = text.filter { !$0.isWhitespace }.count
      guard letters >= 3, Float(letters) / Float(max(visible, 1)) >= 0.7,
        text.count <= 60, Set(words(entry.folded)).isDisjoint(with: notAName),
        days(in: entry.folded).isEmpty, times(in: entry.folded).isEmpty
      else { continue }
      // The first name-like line decides: a dim one means the shop was not read well.
      return (entry.confidence ?? 0) >= merchantConfidence ? text : nil
    }
    return nil
  }

  // MARK: Folding

  /// Lower case without accents: `Ё` is `е`, `Ə` is `e`, `İ` is `i`, so one spelling is searched.
  static func fold(_ text: String) -> String {
    var result = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    result = result.replacingOccurrences(of: "ə", with: "e").replacingOccurrences(
      of: "ı", with: "i")
    return result.trimmingCharacters(in: .whitespaces)
  }

  private static func words(_ line: String) -> [String] {
    line.split(whereSeparator: { !$0.isLetter }).map(String.init)
  }

  // MARK: Kind

  private static let slipMarkers: [String] = [
    "rrn", "auth", "authcode", "terminal", "tid", "mid", "approved", "одобрено", "visa",
    "mastercard", "customer", "cardholder", "contactless", "терминал", "авторизации",
    "approval",
  ]
  private static let billMarkers: [String] = [
    "счет", "bill", "hesab", "hesabi", "чаевые", "gratuity", "invoice",
  ]

  private static func markers(_ list: [String], in lines: [String]) -> Int {
    let present = Set(lines.flatMap(words))
    return list.filter { present.contains($0) }.count
  }

  // MARK: Fiscal numbers

  /// The digits after a label such as «ФН» (the paper writes them with spaces and the camera
  /// reads a zero as the letter O now and then).
  private static func fiscalValue(_ labels: [String], in lines: [String]) -> String? {
    let alternatives = labels.joined(separator: "|")
    let pattern = "(?:^|[^\\p{L}])(?:\(alternatives))[\\s:№#.=-]*([0-9oо][0-9oо \\x{00A0}]*)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    for line in lines {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = expression.firstMatch(in: line, range: range),
        let captured = Range(match.range(at: 1), in: line)
      else { continue }
      let digits = line[captured].compactMap { character -> Character? in
        switch character {
        case "o", "о": "0"
        case let digit where digit.isASCII && digit.isNumber: digit
        default: nil
        }
      }
      if !digits.isEmpty { return String(digits) }
    }
    return nil
  }

  private static func validNumbers(
    drive: String?, document: String?, sign: String?
  )
    -> ReceiptNumbers?
  {
    guard let drive, let document, let sign, drive.count == 16, (1...10).contains(document.count),
      (1...10).contains(sign.count)
    else { return nil }
    return ReceiptNumbers(
      fiscalDrive: drive, documentNumber: document, fiscalSign: sign, operation: nil)
  }

  // MARK: Total

  private static let strongTotals = ["итог", "итого", "total", "всего", "cemi", "cemi:"]
  private static let weakTotals = ["сумма", "amount", "sale", "продажа", "mebleg", "sum"]
  private static let notATotal = [
    "ндс", "nds", "vat", "edv", "tax", "налог", "vergi", "сдача", "change", "cashback", "tip",
    "чаевые",
  ]

  private static func total(
    in lines: [String], kind: PaperKind
  )
    -> (amount: AmountE4, currency: CurrencyCode?)?
  {
    // A slip says «sale» or «amount»; a «total» beside it is the bill's, not what was paid.
    for tier in kind == .slip ? [weakTotals, strongTotals] : [strongTotals, weakTotals] {
      for (index, line) in lines.enumerated() {
        let present = Set(words(line))
        guard
          tier.contains(where: present.contains)
            || (tier == strongTotals && line.contains("к оплате")),
          !notATotal.contains(where: present.contains)
        else { continue }
        // The sum is on the next line only when this one has no digits at all.
        let hasDigits = line.contains { $0.isASCII && $0.isNumber }
        for candidate in [line] + (!hasDigits && index + 1 < lines.count ? [lines[index + 1]] : [])
        {
          if let amount = amount(on: candidate) {
            return (amount, currency(in: [candidate]) ?? currency(in: [line]))
          }
        }
      }
    }
    return nil
  }

  /// The last number with decimals on the line; a number without them only when the line names
  /// a currency (so «ИТОГ 2 поз.» is not a sum).
  private static func amount(on line: String) -> AmountE4? {
    guard
      let expression = try? NSRegularExpression(
        pattern:
          "\\d{1,3}(?:[ \\x{00A0}'.,]\\d{3})+(?:[.,]\\d{1,4})?(?![\\d])|\\d+(?:[.,]\\d{1,4})?")
    else { return nil }
    let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
    let tokens = matches.compactMap { Range($0.range, in: line).map { String(line[$0]) } }
    let parsed = tokens.compactMap { token -> (AmountE4, Bool)? in
      guard let value = parse(sum: token) else { return nil }
      return (value.amount, value.hasDecimals)
    }
    if let withDecimals = parsed.last(where: { $0.1 }) { return withDecimals.0 }
    return currency(in: [line]) != nil ? parsed.last?.0 : nil
  }

  /// `1 250,50`, `1,250.50`, `1250.5`, `12`. A separator followed by exactly three digits and
  /// nothing after is a thousands mark.
  static func parse(sum token: String) -> (amount: AmountE4, hasDecimals: Bool)? {
    let cleaned = token.replacingOccurrences(of: "\u{00A0}", with: " ")
    var integer = cleaned
    var fraction = ""
    if let split = cleaned.lastIndex(where: { $0 == "." || $0 == "," }) {
      let tail = cleaned[cleaned.index(after: split)...]
      let isThousands = tail.count == 3
      if !isThousands {
        integer = String(cleaned[..<split])
        fraction = String(tail)
      }
    }
    integer = integer.filter { $0.isASCII && $0.isNumber }
    guard !integer.isEmpty,
      let decimal = Decimal(
        string: fraction.isEmpty ? integer : "\(integer).\(fraction)",
        locale: Locale(identifier: "en_US_POSIX")),
      let amount = try? AmountE4(decimal: decimal), amount.raw > 0, amount <= AmountE4.inputLimit
    else { return nil }
    return (amount, !fraction.isEmpty)
  }

  // MARK: Currency

  private static let currencyMarks: [(String, CurrencyCode)] = [
    ("₽", .rub), ("rub", .rub), ("руб", .rub), ("azn", CurrencyCode("AZN")),
    ("₼", CurrencyCode("AZN")), ("manat", CurrencyCode("AZN")), ("usd", .usd), ("$", .usd),
    ("eur", .eur), ("€", .eur), ("try", CurrencyCode("TRY")), ("₺", CurrencyCode("TRY")),
    ("gel", CurrencyCode("GEL")), ("₾", CurrencyCode("GEL")), ("aed", CurrencyCode("AED")),
    ("kzt", CurrencyCode("KZT")), ("₸", CurrencyCode("KZT")),
  ]

  private static func currency(in lines: [String]) -> CurrencyCode? {
    for line in lines {
      let present = Set(words(line))
      for (mark, code) in currencyMarks {
        if mark.count <= 1 || mark == "руб" {
          if line.contains(mark) { return code }
        } else if present.contains(mark) {
          return code
        }
      }
    }
    return nil
  }

  // MARK: Moment

  private static func moment(
    in lines: [String]
  )
    -> (day: DateOnly, time: TimeOfDay, second: Int?)?
  {
    var firstDay: DateOnly?
    var firstTime: (TimeOfDay, Int?)?
    for line in lines {
      let day = days(in: line).first
      let time = times(in: line).first
      if let day, let time { return (day, time.0, time.1) }
      if firstDay == nil { firstDay = day }
      if firstTime == nil { firstTime = time }
    }
    guard let firstDay, let firstTime else { return nil }
    return (firstDay, firstTime.0, firstTime.1)
  }

  private static func days(in line: String) -> [DateOnly] {
    guard
      let expression = try? NSRegularExpression(
        pattern:
          "(?<!\\d)(?:(\\d{4})[-./](\\d{1,2})[-./](\\d{1,2})|(\\d{1,2})[-./](\\d{1,2})[-./](\\d{4}|\\d{2}))(?!\\d)"
      )
    else { return [] }
    func group(_ match: NSTextCheckingResult, _ index: Int) -> Int? {
      Range(match.range(at: index), in: line).flatMap { Int(line[$0]) }
    }
    return expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
      match in
      var year: Int?
      var month: Int?
      var dayNumber: Int?
      if let first = group(match, 1) {
        (year, month, dayNumber) = (first, group(match, 2), group(match, 3))
      } else {
        let first = group(match, 4)
        let second = group(match, 5)
        year = group(match, 6).map { $0 < 100 ? 2000 + $0 : $0 }
        // Day first, as in every country read here; month first only when it cannot be a month.
        if let first, let second, second > 12, first <= 12 {
          (month, dayNumber) = (first, second)
        } else {
          (dayNumber, month) = (first, second)
        }
      }
      guard let year, let month, let dayNumber, (2000...2100).contains(year),
        (1...12).contains(month), (1...31).contains(dayNumber)
      else { return nil }
      let day = DateOnly(year: year, month: month, day: dayNumber)
      return CalendarContext.utc.day(of: CalendarContext.utc.startOfDay(day)) == day ? day : nil
    }
  }

  private static func times(in line: String) -> [(TimeOfDay, Int?)] {
    guard
      let expression = try? NSRegularExpression(
        pattern: "(?<![\\d:])([01]?\\d|2[0-3]):([0-5]\\d)(?::([0-5]\\d))?(?![\\d])")
    else { return [] }
    return expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
      match in
      func group(_ index: Int) -> Int? {
        Range(match.range(at: index), in: line).flatMap { Int(line[$0]) }
      }
      guard let hour = group(1), let minute = group(2) else { return nil }
      return (TimeOfDay(hour: hour, minute: minute), group(3))
    }
  }
}
