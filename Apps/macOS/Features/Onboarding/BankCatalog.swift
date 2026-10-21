import AppCore
import Foundation

/// The banks the setup of the accounts offers with one click: names only, no logos. A name
/// written the same way in both languages is given once; the others have a Russian and an
/// English spelling, and an account already named either way is that bank.
///
/// Proper names, not interface text: they stay here rather than in a String Catalog.
enum BankCatalog {
  enum Country: String, CaseIterable, Hashable, Sendable {
    case russia, kazakhstan

    /// What an account of a bank of the country holds when it is added.
    var currency: CurrencyCode {
      switch self {
      case .russia: .rub
      case .kazakhstan: CurrencyCode("KZT")
      }
    }

    /// The key of the country's name in the Onboarding table: a group of accounts is
    /// suggested under it.
    var nameKey: String {
      switch self {
      case .russia: "onboarding.country.russia"
      case .kazakhstan: "onboarding.country.kazakhstan"
      }
    }
  }

  struct Bank: Identifiable, Hashable, Sendable {
    /// A stable token, never shown.
    let id: String
    let country: Country
    let russian: String
    let english: String

    /// The name in the interface language: Russian for `ru`, English for any other.
    func name(languageCode: String) -> String {
      languageCode == "ru" ? russian : english
    }

    /// Every spelling of the name, each once.
    var names: [String] { russian == english ? [russian] : [russian, english] }
  }

  /// In the order they are offered: the ten Russian banks, then the five of Kazakhstan.
  static let banks: [Bank] = [
    Bank(id: "sber", country: .russia, russian: "Сбер", english: "Sber"),
    Bank(id: "tbank", country: .russia, russian: "Т-Банк", english: "T-Bank"),
    Bank(id: "vtb", country: .russia, russian: "ВТБ", english: "VTB"),
    Bank(id: "alfa", country: .russia, russian: "Альфа-Банк", english: "Alfa-Bank"),
    Bank(id: "gazprombank", country: .russia, russian: "Газпромбанк", english: "Gazprombank"),
    Bank(id: "sovcombank", country: .russia, russian: "Совкомбанк", english: "Sovcombank"),
    Bank(id: "ozon", country: .russia, russian: "Озон Банк", english: "Ozon Bank"),
    Bank(id: "raiffeisen", country: .russia, russian: "Райффайзенбанк", english: "Raiffeisenbank"),
    Bank(
      id: "rosselkhozbank", country: .russia, russian: "Россельхозбанк",
      english: "Rosselkhozbank"),
    Bank(id: "psb", country: .russia, russian: "ПСБ", english: "PSB"),
    Bank(id: "kaspi", country: .kazakhstan, russian: "Kaspi", english: "Kaspi"),
    Bank(id: "halyk", country: .kazakhstan, russian: "Halyk", english: "Halyk"),
    Bank(id: "freedom", country: .kazakhstan, russian: "Freedom", english: "Freedom"),
    Bank(
      id: "centercredit", country: .kazakhstan, russian: "Банк ЦентрКредит",
      english: "Bank CenterCredit"),
    Bank(id: "forte", country: .kazakhstan, russian: "ForteBank", english: "ForteBank"),
  ]

  static func banks(in country: Country) -> [Bank] {
    banks.filter { $0.country == country }
  }

  /// Cash in every language of the app, as the Onboarding table spells it: an account a
  /// database of the other language called «Cash» is that cash too.
  static var cashNames: [String] {
    var names: [String] = []
    for code in ["ru", "en"] {
      guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
        let bundle = Bundle(path: path)
      else { continue }
      let name = bundle.localizedString(forKey: "onboarding.cash", value: nil, table: "Onboarding")
      if name != "onboarding.cash", !names.contains(name) { names.append(name) }
    }
    return names
  }

  /// The bank an account name spells, in either language, whatever the case.
  static func bank(named name: String) -> Bank? {
    let key = AccountSetupModel.nameKey(name)
    return banks.first { bank in bank.names.contains { AccountSetupModel.nameKey($0) == key } }
  }
}
