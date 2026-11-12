import CoreKit
import Foundation

/// One column of a format: what the n-th group of the expression holds.
public enum SmsColumn: Hashable, Sendable {
  /// Money that came / left, in the account's currency.
  case income, outcome
  /// The same in the currency of the operation (a foreign purchase from a ruble card).
  case opIncome, opOutcome
  case fee, cashback
  /// What is left on the card; what is available (a credit card's limit included).
  case balance, availableBalance
  /// The currency of `income`, `outcome`, `fee`, `cashback` and the balances; of `opIncome`
  /// and `opOutcome`.
  case instrument, opInstrument
  case payee, comment
  /// Last digits of the card, of the account.
  case card, account
  case mcc, syncid
  /// A time of day: `HH:mm` or `HH:mm:ss`.
  case time
  /// A day (and maybe a time) written by the pattern: `dd.MM.yy`, `dd.MM.yyyy HH:mm`.
  case date(String)
  /// A group the format needs and does not use: written as an empty name.
  case skip

  static let datePrefix = "date#"

  public init?(name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "": self = .skip
    case "income": self = .income
    case "outcome": self = .outcome
    case "op_income": self = .opIncome
    case "op_outcome": self = .opOutcome
    case "fee": self = .fee
    case "cashback": self = .cashback
    case "balance": self = .balance
    case "av_balance": self = .availableBalance
    case "instrument": self = .instrument
    case "op_instrument": self = .opInstrument
    case "payee": self = .payee
    case "comment": self = .comment
    case "card": self = .card
    case "account": self = .account
    case "mcc": self = .mcc
    case "syncid": self = .syncid
    case "time": self = .time
    default:
      guard trimmed.hasPrefix(Self.datePrefix) else { return nil }
      let pattern = String(trimmed.dropFirst(Self.datePrefix.count))
      guard !pattern.isEmpty else { return nil }
      self = .date(pattern)
    }
  }

  public var name: String {
    switch self {
    case .skip: ""
    case .income: "income"
    case .outcome: "outcome"
    case .opIncome: "op_income"
    case .opOutcome: "op_outcome"
    case .fee: "fee"
    case .cashback: "cashback"
    case .balance: "balance"
    case .availableBalance: "av_balance"
    case .instrument: "instrument"
    case .opInstrument: "op_instrument"
    case .payee: "payee"
    case .comment: "comment"
    case .card: "card"
    case .account: "account"
    case .mcc: "mcc"
    case .syncid: "syncid"
    case .time: "time"
    case .date(let pattern): Self.datePrefix + pattern
    }
  }

  /// Columns that carry an amount of an operation: a format without one only gives
  /// information (a code, a balance, an advert) and creates nothing.
  var carriesOperationAmount: Bool {
    switch self {
    case .income, .outcome, .opIncome, .opOutcome, .fee, .cashback: true
    default: false
    }
  }
}

/// A reason a format file cannot be used. The text shown is the catalog string under `key`
/// with `arguments` filled in.
public enum SmsFormatProblem: Error, Hashable, Sendable {
  case notText
  case missingPattern
  case invalidPattern
  case missingColumns
  case unknownColumn(String)
  case duplicateColumn(String)
  case badDateFormat(String)
  case unknownOperation(String)
  case unknownSection(String)
  case groupCountMismatch(groups: Int, columns: Int)
  case noExamples
  /// The n-th example (from 1) does not match the expression.
  case exampleDoesNotMatch(Int)
  /// The n-th example is matched, but a column cannot be read from it.
  case exampleUnreadable(Int, column: String)
  /// The n-th example also matches the format `other` of the same bank.
  case exampleMatchesOther(Int, other: String)
  case badCategoryFile
  case badSenders

  public var key: String {
    switch self {
    case .notText: "smsFormat.problem.notText"
    case .missingPattern: "smsFormat.problem.missingPattern"
    case .invalidPattern: "smsFormat.problem.invalidPattern"
    case .missingColumns: "smsFormat.problem.missingColumns"
    case .unknownColumn: "smsFormat.problem.unknownColumn"
    case .duplicateColumn: "smsFormat.problem.duplicateColumn"
    case .badDateFormat: "smsFormat.problem.badDateFormat"
    case .unknownOperation: "smsFormat.problem.unknownOperation"
    case .unknownSection: "smsFormat.problem.unknownSection"
    case .groupCountMismatch: "smsFormat.problem.groupCountMismatch"
    case .noExamples: "smsFormat.problem.noExamples"
    case .exampleDoesNotMatch: "smsFormat.problem.exampleDoesNotMatch"
    case .exampleUnreadable: "smsFormat.problem.exampleUnreadable"
    case .exampleMatchesOther: "smsFormat.problem.exampleMatchesOther"
    case .badCategoryFile: "smsFormat.problem.badCategoryFile"
    case .badSenders: "smsFormat.problem.badSenders"
    }
  }

  /// Values for the placeholders of the catalog string, in order.
  public var arguments: [String] {
    switch self {
    case .unknownColumn(let name), .duplicateColumn(let name), .badDateFormat(let name),
      .unknownOperation(let name), .unknownSection(let name):
      [name]
    case .groupCountMismatch(let groups, let columns): [String(groups), String(columns)]
    case .exampleDoesNotMatch(let number): [String(number)]
    case .exampleUnreadable(let number, let column): [String(number), column]
    case .exampleMatchesOther(let number, let other): [String(number), other]
    default: []
    }
  }
}

/// A format of a bank's text: an expression whose groups are named by the columns, and examples
/// that the expression has to read. Written as a plain text file:
///
///     ^Покупка (\d+)р (.+)$
///     -----COLUMNS-----
///     outcome;payee
///     -----OPERATION-----
///     purchase
///     -----EXAMPLE-----
///     Покупка 450р SAMPLE CAFE
///
/// `BANK` and `OPERATION` are optional; `EXAMPLE` repeats. A format without an amount column
/// only gives information and creates no operation.
public struct SmsFormat: Hashable, Sendable, Identifiable {
  public var id: String
  public var bank: BankBrand
  public var pattern: String
  public var columns: [SmsColumn]
  /// What the text is, when the columns do not say (a refund, cash, a transfer in). Without
  /// it `outcome` is a purchase and `income` is income.
  public var operation: BankOperation?
  public var examples: [String]

  public init(
    id: String, bank: BankBrand = .unknown, pattern: String, columns: [SmsColumn],
    operation: BankOperation? = nil, examples: [String]
  ) {
    self.id = id
    self.bank = bank
    self.pattern = pattern
    self.columns = columns
    self.operation = operation
    self.examples = examples
  }

  /// Information only: no amount to write.
  public var isInformational: Bool { !columns.contains(where: \.carriesOperationAmount) }

  // MARK: - File

  static let columnsMarker = "-----COLUMNS-----"
  static let exampleMarker = "-----EXAMPLE-----"
  static let operationMarker = "-----OPERATION-----"
  static let bankMarker = "-----BANK-----"

  /// Reads the text of a format file. Fails on anything that makes the file unusable; what the
  /// owner can still fix by hand (an example that does not fit) is for `SmsFormatValidator`.
  public static func parse(fileText: String, id: String) -> Result<SmsFormat, SmsFormatProblem> {
    let lines = fileText.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    var pattern: String?
    var sections: [(name: String, lines: [String])] = []
    for line in lines {
      if line.hasPrefix("-----"), line.hasSuffix("-----"), line.count > 10 {
        sections.append((line, []))
      } else if sections.isEmpty {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if pattern == nil, !trimmed.isEmpty { pattern = line }
      } else {
        sections[sections.count - 1].lines.append(line)
      }
    }
    guard let pattern else { return .failure(.missingPattern) }
    var columns: [SmsColumn]?
    var operation: BankOperation?
    var bank = BankBrand.unknown
    var examples: [String] = []
    for section in sections {
      let body = section.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
      switch section.name {
      case columnsMarker:
        let names = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var parsed: [SmsColumn] = []
        for name in names {
          guard let column = SmsColumn(name: name) else {
            return .failure(.unknownColumn(name.trimmingCharacters(in: .whitespaces)))
          }
          parsed.append(column)
        }
        columns = parsed
      case operationMarker:
        let name = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = BankOperation(rawValue: name) else {
          return .failure(.unknownOperation(name))
        }
        operation = value
      case bankMarker:
        bank = BankBrand(rawValue: body.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
      case exampleMarker:
        if !body.isEmpty { examples.append(body) }
      default:
        return .failure(.unknownSection(section.name))
      }
    }
    guard let columns, !columns.isEmpty else { return .failure(.missingColumns) }
    return .success(
      SmsFormat(
        id: id, bank: bank, pattern: pattern, columns: columns, operation: operation,
        examples: examples))
  }

  /// The text of the file this format is read from.
  public var fileText: String {
    var out = [pattern, Self.columnsMarker, columns.map(\.name).joined(separator: ";")]
    if let operation { out += [Self.operationMarker, operation.rawValue] }
    if bank != .unknown { out += [Self.bankMarker, bank.rawValue] }
    for example in examples { out += [Self.exampleMarker, example] }
    return out.joined(separator: "\n") + "\n"
  }
}
