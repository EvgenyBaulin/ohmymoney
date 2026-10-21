import Foundation

/// What may stand on the right of `key=` in a log line.
///
/// There is no case for money, for a person, for a category, a place or a description — and
/// that is the whole point. The log may hold none of them («Чего в журнале быть не
/// должно»), and a rule that lives only in a reviewer's memory is a rule that is broken the
/// first tired evening. Here it is the type: to write an amount into the log somebody would
/// have to add a case for it first, and that is a change worth noticing.
///
/// `token` is the one case that carries words, and it takes only short ones of our own
/// vocabulary — `cbr`, `mirror`, `ok`. A note, a name or a category would fail its rule and
/// be written as `<not-a-token>` instead.
public enum LogValue: Hashable, Sendable {
  case id(UUID)
  case count(Int)
  case bytes(Int)
  case milliseconds(Int)
  /// A version of something: `1.0.0`, `macOS 26.0`, a schema number.
  case version(String)
  /// A short word of our own: a source, an outcome, a step name.
  case token(String)
  /// A source file of ours — `OhMyMoney/TransactionsRootView.swift`. Longer than a token and
  /// allowed a path, because a stand-in that fires is only useful with the file that asked.
  case file(String)
  /// The name of a type of ours or of a framework — above all the type of a caught error,
  /// which every logged error has to name. Longer than a token: the type is the one
  /// thing a failure line has to say, and a long one must not come out `<not-a-token>`.
  /// Made by `error(_:)` from the error itself, so only a name from code can reach it.
  case typeName(String)
  case flag(Bool)

  /// The type of a caught error, by name — never its description.
  public static func error(_ error: any Error) -> LogValue {
    .typeName(String(describing: type(of: error)))
  }

  /// Up to this many characters, and only these: a word of ours is short and ASCII. Anything
  /// else — Cyrillic, spaces, punctuation — is somebody's note, not a token.
  static let tokenLimit = 24

  static func isToken(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= tokenLimit else { return false }
    return text.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "." || character == "-"
          || character == "_" || character == "/")
    }
  }

  static let fileLimit = 64

  /// A Swift type name: an identifier, dotted when nested, with its generic arguments. The
  /// space after a comma of `Result<Int, Failure>` is dropped, so the value stays one word.
  static let typeNameLimit = 64

  static func isTypeName(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= typeNameLimit else { return false }
    return text.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "." || character == "_"
          || character == "<" || character == ">" || character == ",")
    }
  }

  static func isFile(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= fileLimit else { return false }
    return text.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "." || character == "-"
          || character == "_" || character == "/" || character == "+")
    }
  }

  /// A frame is longer than any word of ours: a symbol, mangled or not, runs to hundreds.
  static let frameLimit = 512

  /// One frame of a call stack as `Thread.callStackSymbols` gives it — a number, a module, an
  /// address, then the symbol:
  ///
  ///     3   OhMyMoney.debug.dylib   0x0000000104c2f1a8 $s5OhMyMoney9AppLaunchO5start… + 1234
  ///
  /// Printable ASCII, as symbols are, and no quote. A description of an error is not a frame:
  /// it may quote a statement, its arguments or a path, and the owner's note with them.
  static func isFrame(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= frameLimit else { return false }
    guard
      text.allSatisfy({ character in
        guard let code = character.asciiValue else { return false }
        return code >= 0x20 && code < 0x7F && character != "\""
      })
    else { return false }
    let fields = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    guard fields.count == 4, fields[0].allSatisfy(\.isNumber), fields[2].hasPrefix("0x") else {
      return false
    }
    let address = fields[2].dropFirst(2)
    return !address.isEmpty && address.allSatisfy(\.isHexDigit)
  }

  /// A version is a token with digits and dots, and may hold one space: `macOS 26.0`.
  static func isVersion(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= tokenLimit else { return false }
    return text.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "." || character == "-"
          || character == " ")
    }
  }

  public var text: String {
    switch self {
    case .id(let value): value.uuidString
    case .count(let value): String(value)
    case .bytes(let value): "\(value)b"
    case .milliseconds(let value): "\(value)ms"
    case .version(let value): Self.isVersion(value) ? value : "<not-a-version>"
    case .token(let value): Self.isToken(value) ? value : "<not-a-token>"
    case .file(let value): Self.isFile(value) ? value : "<not-a-file>"
    case .typeName(let value):
      Self.isTypeName(value.replacingOccurrences(of: ", ", with: ","))
        ? value.replacingOccurrences(of: ", ", with: ",") : "<not-a-type>"
    case .flag(let value): value ? "yes" : "no"
    }
  }
}

/// One `key=value` of a line. The key is written in code and is a token too.
public struct LogPair: Hashable, Sendable {
  public var key: String
  public var value: LogValue

  public init(_ key: String, _ value: LogValue) {
    self.key = key
    self.value = value
  }

  public var text: String {
    "\(LogValue.isToken(key) ? key : "<not-a-key>")=\(value.text)"
  }
}
