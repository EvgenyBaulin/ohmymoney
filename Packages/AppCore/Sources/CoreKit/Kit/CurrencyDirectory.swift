import Foundation

/// What Settings → Currencies shows about one currency besides its code: the flag and the
/// country, the full name, and the words a search looks in.
public struct CurrencyEntry: Hashable, Sendable, Identifiable {
  public var id: CurrencyCode { code }
  public let code: CurrencyCode
  /// The flag emoji of the country the currency belongs to; `nil` for a currency with no one
  /// country (the special drawing right, a coin, an own currency).
  public let flag: String?
  /// What stands in the flag's place when there is none: the owner's symbol, or the first
  /// letter of the name.
  public let badge: String
  /// «Казахстанский тенге», «Kazakhstani Tenge»; an own currency keeps the owner's words.
  public let name: String
  /// The country or region in the interface language: «Казахстан», «США»; `nil` when none.
  public let country: String?
  /// An own currency (a coin, points) typed in by the owner.
  public let isCustom: Bool
  /// Lowercased, accent-free words a query is looked for in: code, symbol, the name and the
  /// country in both interface languages.
  let searchTerms: [String]
}

/// The countries and names of currencies, read from the system's own tables, with a short list
/// of what those tables get wrong for this app. Pure: the language is passed in.
public enum CurrencyDirectory {
  /// Currencies whose country is not the first two letters of the code.
  static let regionExceptions: [String: String] = [
    "EUR": "EU", "ANG": "CW", "XCD": "AG", "XOF": "SN", "XAF": "CM", "XPF": "PF",
  ]

  /// Codes of a currency shared by several countries: no flag of one of them stands for it.
  /// The euro is the one exception, it has the flag of the union.
  static let withoutCountry: Set<String> = [
    "XCD", "XOF", "XAF", "XPF", "ANG", "XDR", "XAU", "XAG", "XPT", "XPD", "XTS", "XXX",
    "XSU", "XUA", "XBA", "XBB", "XBC", "XBD", "CHE", "CHW", "USN", "UYI", "BOV", "CLF", "COU",
    "MXV",
  ]

  /// Short names of countries the short Russian form of is the usual one.
  private static let russianCountries: [String: String] = [
    "US": "США", "AE": "ОАЭ", "EU": "Еврозона",
  ]
  /// Russian names the system writes differently from how the owner reads them.
  private static let russianNames: [String: String] = ["KZT": "Казахстанский тенге"]
  private static let englishCountries: [String: String] = ["EU": "Eurozone"]

  /// The ISO 3166 region a currency belongs to, `nil` for a code with no single country.
  public static func region(of code: CurrencyCode) -> String? {
    guard ISOCurrencies.codes.contains(code.code), !withoutCountry.contains(code.code)
    else { return nil }
    if let region = regionExceptions[code.code] { return region }
    let region = String(code.code.prefix(2))
    return Locale.Region(region).isISORegion ? region : nil
  }

  /// The flag emoji of a region: its two letters as regional indicators. `nil` for anything
  /// but two capital Latin letters.
  public static func flag(forRegion region: String) -> String? {
    let letters = region.uppercased().unicodeScalars
    guard letters.count == 2, letters.allSatisfy({ ("A"..."Z").contains($0) }) else {
      return nil
    }
    var flag = ""
    for letter in letters {
      guard let scalar = Unicode.Scalar(0x1F1E6 + letter.value - 0x41) else { return nil }
      flag.unicodeScalars.append(scalar)
    }
    return flag
  }

  /// The entry of a currency in `language` («ru», «en»). A custom currency of the catalog is
  /// the owner's: its name and symbol, no flag, no country.
  public static func entry(
    for code: CurrencyCode, catalog: CurrencyCatalog = .empty, language: String
  ) -> CurrencyEntry {
    if let own = catalog.currency(code) {
      let name = catalog.name(code, language: language) ?? code.code
      let badge = catalog.symbol(code) ?? String(name.prefix(1)).uppercased()
      return CurrencyEntry(
        code: code, flag: nil, badge: badge, name: name, country: nil, isCustom: true,
        searchTerms: terms([code.code, name, own.symbol ?? ""]))
    }
    let region = region(of: code)
    let name = fullName(of: code, language: language)
    let country = region.flatMap { countryName($0, language: language) }
    var words = [code.code, fullName(of: code, language: "ru"), fullName(of: code, language: "en")]
    if let region {
      words += [countryName(region, language: "ru"), countryName(region, language: "en")]
        .compactMap { $0 }
    }
    return CurrencyEntry(
      code: code, flag: region.flatMap(flag(forRegion:)), badge: String(code.code.prefix(1)),
      name: name, country: country, isCustom: false, searchTerms: terms(words))
  }

  /// The full name of a currency of the bank: «Доллар США», «Euro». The code itself when the
  /// system knows no name.
  public static func fullName(of code: CurrencyCode, language: String) -> String {
    if language == "ru", let own = russianNames[code.code] { return own }
    let locale = Locale(identifier: language)
    guard let name = locale.localizedString(forCurrencyCode: code.code), name != code.code,
      !name.isEmpty
    else { return code.code }
    return String(name.prefix(1)).uppercased() + name.dropFirst()
  }

  /// The country or region in `language`, short where the language prefers it.
  public static func countryName(_ region: String, language: String) -> String? {
    if language == "ru", let short = russianCountries[region] { return short }
    if language != "ru", let short = englishCountries[region] { return short }
    return Locale(identifier: language).localizedString(forRegionCode: region)
  }

  /// Whether `entry` answers `query`: every word of the query starts a word of the entry's
  /// code, symbol, names or countries, or is part of one of them; case and accents ignored. An
  /// empty query answers everything.
  public static func matches(_ entry: CurrencyEntry, query: String) -> Bool {
    let words = terms([query])
    guard !words.isEmpty else { return true }
    return words.allSatisfy { word in entry.searchTerms.contains { $0.contains(word) } }
  }

  /// `codes` the query answers, in their order.
  public static func filter(
    _ codes: [CurrencyCode], query: String, catalog: CurrencyCatalog = .empty, language: String
  ) -> [CurrencyCode] {
    codes.filter {
      matches(entry(for: $0, catalog: catalog, language: language), query: query)
    }
  }

  /// The currencies the list shows. Without a query, the enabled ones of the bank (not the
  /// ruble, every rate is against it) and the own currencies not archived; with a query, or
  /// when `showsAll`, everything `offered` as well, the ruble too, narrowed to what the query
  /// answers. Nothing comes twice.
  public static func listed(
    enabled: [CurrencyCode], offered: [CurrencyCode], catalog: CurrencyCatalog, query: String,
    showsAll: Bool, language: String
  ) -> [CurrencyCode] {
    let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let wide = searching || showsAll
    let bank = (wide ? offered : enabled.filter { $0 != .rub }).filter { !catalog.isCustom($0) }
    var seen = Set<CurrencyCode>()
    let all = (wide ? [.rub] + bank : bank) + catalog.active.map(\.code)
    let unique = all.filter { seen.insert($0).inserted }
    return filter(unique, query: query, catalog: catalog, language: language)
  }

  /// Lowercased, accent-free pieces: a phrase is kept whole and also split into words.
  private static func terms(_ phrases: [String]) -> [String] {
    var all: [String] = []
    for phrase in phrases {
      let folded = phrase.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: nil
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !folded.isEmpty else { continue }
      all.append(folded)
      all += folded.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
    }
    return all
  }
}

/// Which rate of the table stands for a currency, and where it came from.
public enum CurrencyRateInfo {
  /// Where a rate shown beside a currency comes from.
  public enum Origin: Hashable, Sendable {
    case bank
    case network
    case manual
    case imported
  }

  /// The rate of the latest day the table holds for `code`; of two on one day a rate the owner
  /// typed or imported wins, it is never overwritten.
  public static func latest(for code: CurrencyCode, in rates: [Rate]) -> Rate? {
    var best: Rate?
    for rate in rates where rate.currency == code {
      guard let current = best else {
        best = rate
        continue
      }
      if rate.date > current.date
        || (rate.date == current.date && rate.source.isProtected && !current.source.isProtected)
      {
        best = rate
      }
    }
    return best
  }

  public static func origin(of source: RateSource) -> Origin {
    switch source {
    case .cbr, .cbrMirror: .bank
    case .coingecko: .network
    case .manual: .manual
    case .imported: .imported
    }
  }
}
