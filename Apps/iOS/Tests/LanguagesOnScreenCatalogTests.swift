import XCTest

@testable import OhMyMoney

/// A «%» in prose is not an argument (Azerbaijani writes «4%-dən», English «4 % from»); the reader
/// below takes only the flag the app's formats use (`0`) so such a text is not misread.
///
/// Every language the app ships, read from the compiled bundle the way the app reads it: no text
/// is its own key (a key on screen instead of words), and a translation takes the arguments of
/// the English text, in kind and in number, so a format cannot read a number as an object or
/// drop the count. A language with no strings at all is not an error here: the app falls back to
/// English for it (`AppLanguage.localizedText`), and its share of translated lines is reported
/// by the lane log, not by a test.
final class LanguagesOnScreenCatalogTests: XCTestCase {
  private static let shipped = AppLanguage.Choice.allCases.filter { $0 != .system }

  private func folder(_ code: String) -> URL? {
    Bundle.main.url(forResource: code, withExtension: "lproj")
  }

  /// The specifiers of a format text as `type` for each one, ordered by position: `%1$@ … %2$lld`
  /// and `%@ … %lld` both read as `[@, lld]`; `%%` is not an argument.
  static func arguments(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(
      pattern: "%(?:(\\d+)\\$)?(?:#@[A-Za-z0-9_]+@|0*\\d*(?:\\.\\d+)?(@|lld|ld|d|u|f|%))")
    var found: [(position: Int, type: String)] = []
    var next = 1
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      let whole = String(text[Range(match.range, in: text)!])
      if whole == "%%" { continue }
      let type = whole.hasPrefix("%#@") ? whole : whole.replacingOccurrences(
        of: "%(\\d+\\$)?0*\\d*(\\.\\d+)?", with: "", options: .regularExpression)
      var position = next
      if match.range(at: 1).location != NSNotFound,
        let range = Range(match.range(at: 1), in: text), let given = Int(text[range])
      {
        position = given
      } else {
        next += 1
      }
      found.append((position, type))
    }
    return found.sorted { $0.position < $1.position }.map(\.type)
  }

  private func tables(in url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path)
      .filter { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
  }

  /// The texts to compare of one entry: the string itself, or the outer format of a plural entry
  /// (the inner forms may say their number in words).
  private func comparable(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let plural = value as? [String: Any] {
      return plural["NSStringLocalizedFormatKey"] as? String
    }
    return nil
  }

  private var bundles: [String: Bundle] = [:]

  private func bundle(_ code: String) -> Bundle {
    if let known = bundles[code] { return known }
    let made = folder(code).flatMap(Bundle.init(url:)) ?? Bundle.main
    bundles[code] = made
    return made
  }

  /// What the app shows for `key` in `code`: the language's text, else the English one, else the
  /// key itself (`AppLanguage.localizedText`). A compiled language table may hold a missing line
  /// as its own key; the app then reads English, so that is not what the user sees.
  private func shown(_ key: String, table: String, in code: String) -> String {
    let selected = bundle(code)
    let fallback = bundle("en")
    return AppLanguage.localizedText(
      key, table: table, forTouch: false, in: selected, fallback: fallback)
  }

  func testNoLanguageShowsAKeyInsteadOfText() throws {
    let english = try XCTUnwrap(folder("en"))
    var read = 0
    var problems: [String] = []
    for table in try tables(in: english) where table.hasSuffix(".strings") {
      let name = String(table.dropLast(".strings".count))
      let base =
        NSDictionary(contentsOf: english.appendingPathComponent(table)) as? [String: String] ?? [:]
      for choice in Self.shipped {
        for (key, text) in base where text != key {
          read += 1
          let seen = shown(key, table: name, in: choice.rawValue)
          if seen == key {
            problems.append("\(choice.rawValue) \(table) «\(key)» shows its key")
          } else if seen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("\(choice.rawValue) \(table) «\(key)» is empty")
          }
        }
      }
    }
    XCTAssertGreaterThan(read, 100_000, "the walk read almost nothing")
    XCTAssertTrue(problems.isEmpty, problems.prefix(30).joined(separator: "\n"))
  }

  func testEveryTranslationTakesTheArgumentsOfTheEnglishText() throws {
    let english = try XCTUnwrap(folder("en"))
    var compared = 0
    var problems: [String] = []
    for choice in Self.shipped where choice != .english {
      guard let url = folder(choice.rawValue) else { continue }
      for table in try tables(in: url) {
        let source =
          NSDictionary(contentsOf: english.appendingPathComponent(table)) as? [String: Any] ?? [:]
        let translated =
          NSDictionary(contentsOf: url.appendingPathComponent(table)) as? [String: Any] ?? [:]
        for (key, value) in translated {
          guard var theirs = comparable(value), let ours = comparable(source[key]) else {
            continue
          }
          // A line the language does not have is read in English, so it takes English's.
          if theirs == key, table.hasSuffix(".strings") { theirs = ours }
          compared += 1
          let (en, other) = (Self.arguments(ours), Self.arguments(theirs))
          if en != other {
            problems.append(
              "\(choice.rawValue) \(table) «\(key)» takes \(other), English takes \(en)")
          }
        }
      }
    }
    XCTAssertGreaterThan(compared, 10_000, "the walk read almost nothing")
    XCTAssertTrue(problems.isEmpty, "\(problems.count): " + problems.prefix(30).joined(separator: "\n"))
  }

  func testTheSpecifierReaderIsPositionAware() {
    XCTAssertEqual(Self.arguments("%1$@ — %2$lld"), ["@", "lld"])
    XCTAssertEqual(Self.arguments("%2$lld of %1$@"), ["@", "lld"])
    XCTAssertEqual(Self.arguments("100%% of %@"), ["@"])
    XCTAssertEqual(Self.arguments("%#@count@ in %@"), ["%#@count@", "@"])
  }
}
