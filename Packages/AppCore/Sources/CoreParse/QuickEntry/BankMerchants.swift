import CoreKit
import Foundation

/// The shop of a bank text as the owner's list names it. A bank writes «PYATEROCHKA 4512 MOSKVA
/// RUS»; the entry wants «Пятёрочка», and the place of the owner's list when there is one.
public enum BankMerchants {
  public struct Resolved: Hashable, Sendable {
    /// The name to write in the line.
    public var name: String
    /// The place of the owner's list it is, if it is one.
    public var placeId: UUID?
    /// The place came from a spelling the owner's list has (not from the built-in names).
    public var isKnownPlace: Bool
  }

  /// Names of the chains that write Latin in a statement. A key shorter than six letters must
  /// be the whole word; a longer one may stand inside it («pyaterochka» in «pyaterochka4512»).
  static let chains: [(key: String, name: String)] = [
    ("pyaterochka", "Пятёрочка"), ("pyatyorochka", "Пятёрочка"), ("magnit", "Магнит"),
    ("perekrestok", "Перекрёсток"), ("lenta", "Лента"), ("dixy", "Дикси"), ("diksi", "Дикси"),
    ("vkusvill", "ВкусВилл"), ("azbukavkusa", "Азбука вкуса"), ("azbuka", "Азбука вкуса"),
    ("auchan", "Ашан"), ("okey", "О'Кей"), ("samokat", "Самокат"), ("sbermarket", "СберМаркет"),
    ("yandexgo", "Яндекс Go"), ("yandextaxi", "Яндекс Go"), ("yandexeda", "Яндекс Еда"),
    ("yandexlavka", "Яндекс Лавка"), ("yandexmarket", "Яндекс Маркет"), ("ozon", "Ozon"),
    ("wildberries", "Wildberries"), ("mcdonalds", "Макдоналдс"), ("burgerking", "Бургер Кинг"),
    ("kfc", "KFC"), ("starbucks", "Starbucks"), ("rzd", "РЖД"), ("aeroflot", "Аэрофлот"),
    ("mvideo", "М.Видео"), ("letual", "Л'Этуаль"), ("megafon", "МегаФон"), ("beeline", "Билайн"),
    ("mts", "МТС"),
  ]

  /// Strips what a bank adds to a shop: the number of the branch, the country, a star prefix.
  public static func cleaned(_ raw: String) -> String? {
    var tokens = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let countries: Set<String> = ["RUS", "RU", "RUS.", "GEO", "ARM", "KAZ", "TUR", "ARE"]
    func isBranchNumber(_ token: String) -> Bool {
      let digits = token.drop { "#№Nn".contains($0) }
      return digits.count >= 3 && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
    while let last = tokens.last, tokens.count > 1,
      countries.contains(last.uppercased()) || isBranchNumber(last)
    {
      tokens.removeLast()
    }
    let text = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  /// The place a bank text names. The owner's list wins: a place or an alias the text contains
  /// (four letters or more, or the whole text) is that place. Then the built-in chains. Then
  /// the text itself, cleaned, in capitals turned to «Capitals».
  public static func resolve(_ raw: String, places: [ParserVocabulary.Entry] = []) -> Resolved? {
    guard let text = cleaned(raw) else { return nil }
    let folded = NameKey.fold(text)
    let compact = squeezed(text)
    // 1. A spelling of the owner's list: the whole text, or inside it when it is long enough.
    var best: (entry: ParserVocabulary.Entry, length: Int)?
    for place in places {
      for spelling in place.spellings {
        let key = NameKey.fold(spelling)
        guard !key.isEmpty else { continue }
        let squeezedKey = squeezed(spelling)
        let matches =
          key == folded || squeezedKey == compact
          || (squeezedKey.count >= 4 && compact.contains(squeezedKey))
        if matches, squeezedKey.count > (best?.length ?? 0) {
          best = (place, squeezedKey.count)
        }
      }
    }
    if let best {
      return Resolved(name: best.entry.name, placeId: best.entry.id, isKnownPlace: true)
    }
    // 2. The built-in chains, then a place of the owner's list that carries the chain's name.
    for chain in chains {
      let matches =
        chain.key.count >= 6 ? compact.contains(chain.key) : isWhole(chain.key, in: compact)
      guard matches else { continue }
      let wanted = NameKey.fold(chain.name)
      if let place = places.first(where: { NameKey.fold($0.name) == wanted }) {
        return Resolved(name: place.name, placeId: place.id, isKnownPlace: true)
      }
      return Resolved(name: chain.name, placeId: nil, isKnownPlace: false)
    }
    return Resolved(name: capitalised(text), placeId: nil, isKnownPlace: false)
  }

  /// A short chain name must be the whole word, possibly with a branch number or a site ending.
  static func isWhole(_ key: String, in compact: String) -> Bool {
    guard compact.hasPrefix(key) else { return false }
    let rest = compact.dropFirst(key.count)
    return rest.isEmpty || ["ru", "com", "by", "kz"].contains(String(rest))
      || rest.allSatisfy { $0 >= "0" && $0 <= "9" }
  }

  /// Letters and digits only, lower case, «ё» as «е»: the key a statement spelling is compared by.
  static func squeezed(_ text: String) -> String {
    String(NameKey.fold(text).filter { $0.isLetter || $0.isNumber })
  }

  /// «YANDEX GO» is written «Yandex Go»; a text that already has small letters is left alone.
  static func capitalised(_ text: String) -> String {
    guard text.contains(where: \.isLetter), text.filter(\.isLetter).allSatisfy(\.isUppercase)
    else { return text }
    return text.split(separator: " ").map { word in
      word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }.joined(separator: " ")
  }
}
