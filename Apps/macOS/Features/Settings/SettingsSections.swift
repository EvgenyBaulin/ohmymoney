import AppCore
import Foundation
import Observation

/// The sections of the settings, in the order of the sidebar, as System Settings lists its own:
/// a name, a symbol, and the settings each holds — the index the search field reads.
enum SettingsSection: String, CaseIterable, Hashable, Sendable {
  case general
  case appearance
  case currencies
  case accounts
  case categories
  case references
  case entry
  case templates
  case planning
  case backups

  /// The name of the section, a key of the Settings table.
  var titleKey: String {
    switch self {
    case .general: "settings.tab.general"
    case .appearance: "settings.tab.appearance"
    case .currencies: "settings.tab.currencies"
    case .accounts: "settings.tab.accounts"
    case .categories: "settings.tab.categories"
    case .references: "settings.tab.references"
    case .entry: "settings.tab.entry"
    case .templates: "settings.templates"
    case .planning: "settings.tab.planning"
    case .backups: "settings.tab.backups"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintpalette"
    case .currencies: "banknote"
    case .accounts: "building.columns"
    case .categories: "folder"
    case .references: "books.vertical"
    case .entry: "keyboard"
    case .templates: "square.grid.2x2"
    case .planning: "calendar"
    case .backups: "externaldrive"
    }
  }

  /// The captions of the settings the section holds, as keys of the catalogs: what a search
  /// finds a section by besides its name. A caption added to a section is added here, so the
  /// search finds it (`SettingsSearchTests` checks every key has words in both languages).
  var index: [SettingsCaption] {
    switch self {
    case .general:
      [
        .settings("settings.language"), .settings("settings.starter"),
        .settings("settings.tips.off"), .settings("settings.privacy"),
        .settings("settings.privacy.hideAmounts"), .settings("settings.privacy.lock"),
        .settings("settings.privacy.idle"), .settings("settings.privacy.password"),
        .settings("settings.events.automatic"), .settings("settings.forWhomLabels"),
        .settings("settings.forWhom.people"), .settings("settings.updates"),
        .settings("settings.updates.automatic"), .settings("report.title"),
        .sync("sync.folder.title"),
      ]
    case .appearance:
      [
        .settings("settings.appearance.scheme"), .settings("settings.appearance.accent"),
        .settings("settings.appearance.fontSize"), .settings("settings.appearance.currencyStyle"),
        .settings("settings.tiles"),
      ]
    case .currencies:
      [
        .settings("settings.currencies.default"), .settings("settings.currencies.enabled"),
        .settings("currencies.custom"), .settings("currencies.custom.add"),
        .settings("currencies.custom.rates"),
      ]
    case .accounts:
      [
        .accounts("accounts.section.banks"), .accounts("accounts.section.accounts"),
        .accounts("accounts.section.groups"), .accounts("accounts.newBank"),
        .accounts("accounts.newAccount"), .accounts("accounts.newGroup"),
        .accounts("card.cashback"), .accounts("accounts.section.archive"),
        .accounts("account.mainCard"), .accounts("account.credit.title"),
        .settings("accounts.creditTerms"),
      ]
    case .categories:
      [
        .settings("categories.essential"), .settings("categories.cashback"),
        .settings("categories.limit.rollover"), .settings("categories.showArchived"),
        .settings("categories.tax"),
      ]
    case .references:
      [.settings("settings.people"), .settings("settings.places"), .settings("settings.events")]
    case .entry:
      [
        .settings("settings.entry.style"), .settings("settings.entry.order"),
        .overview("overview.small.field.title"),
      ]
    case .templates:
      [.settings("templates.showArchive")]
    case .planning:
      [
        .settings("settings.planning.screen"), .settings("settings.planning.limits"),
        .settings("settings.planning.limitsTopN"), .settings("settings.planning.listLength"),
        .settings("settings.planning.includesGoals"), .settings("settings.planning.goalValuation"),
        .settings("settings.planning.reserve"), .settings("settings.planning.reserveEvents"),
        .settings("settings.planning.cushion"), .settings("settings.planning.cushionOut"),
        .settings("settings.planning.reconciliation"), .settings("settings.planning.savings"),
        .settings("settings.anomalies"), .settings("settings.anomalies.sensitivity"),
        .settings("settings.selfEmployed"), .settings("settings.selfEmployed.enabled"),
        .settings("settings.selfEmployed.deductionLeft"),
        .settings("settings.selfEmployed.taxAccount"),
        .settings("settings.selfEmployed.reference"), .settings("settings.allocation"),
        .settings("settings.allocation.rules"), .settings("settings.hints"),
        .settings("settings.hints.burnout"), .settings("settings.hints.creditHistory"),
      ]
    case .backups:
      [
        .settings("settings.backups.folder"), .settings("settings.backups.choose"),
        .settings("integrity.heading"), .settings("integrity.check"),
        .settings("backups.space.freeUp"), .settings("backups.beforeUpdate.deleteOld"),
      ]
    }
  }
}

/// A caption of a setting: its key and the catalog it is in.
struct SettingsCaption: Hashable, Sendable {
  let key: String
  let table: String

  static func settings(_ key: String) -> SettingsCaption {
    SettingsCaption(key: key, table: "Settings")
  }

  static func accounts(_ key: String) -> SettingsCaption {
    SettingsCaption(key: key, table: "Accounts")
  }

  static func sync(_ key: String) -> SettingsCaption {
    SettingsCaption(key: key, table: "Sync")
  }

  static func overview(_ key: String) -> SettingsCaption {
    SettingsCaption(key: key, table: "Overview")
  }
}

/// The search of the settings: a section is found by its name or by the caption of a setting
/// it holds, in Russian or in English whatever the language of the interface — a setting
/// remembered in one language is found while the app speaks the other.
enum SettingsSearch {
  /// What the sidebar shows for a query: each section found, with the captions that matched —
  /// none when the name of the section did.
  struct Found: Equatable {
    let section: SettingsSection
    let captions: [SettingsCaption]
  }

  /// The words of a key in one language: `code` is «ru» or «en».
  typealias Words = (_ caption: SettingsCaption, _ code: String) -> String

  /// The two languages of the interface.
  static let languages = ["ru", "en"]

  /// The sections and settings `query` finds, in the order of the sidebar. An empty query (or
  /// one of spaces) finds every section, with no captions.
  static func find(_ query: String, words: Words) -> [Found] {
    let wanted = fold(query)
    guard !wanted.isEmpty else {
      return SettingsSection.allCases.map { Found(section: $0, captions: []) }
    }
    return SettingsSection.allCases.compactMap { section in
      let title = SettingsCaption.settings(section.titleKey)
      let byName = languages.contains { fold(words(title, $0)).contains(wanted) }
      let captions = section.index.filter { caption in
        languages.contains { fold(words(caption, $0)).contains(wanted) }
      }
      guard byName || !captions.isEmpty else { return nil }
      return Found(section: section, captions: captions)
    }
  }

  /// Text as the search compares it: no case, no accents, «ё» as «е», the guillemets and the
  /// ellipsis of the captions left out, the spaces around trimmed.
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .replacingOccurrences(of: "ё", with: "е")
      .filter { !"«»“”\"…".contains($0) }
      .trimmingCharacters(in: .whitespaces)
  }

  /// The words of the app's catalogs, read from the `.lproj` of each language — not the
  /// language of the interface alone.
  @MainActor
  static func catalogWords() -> Words {
    var bundles: [String: Bundle] = [:]
    for code in languages {
      if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
        let bundle = Bundle(path: path)
      {
        bundles[code] = bundle
      }
    }
    return { caption, code in
      (bundles[code] ?? .main).localizedString(forKey: caption.key, value: "", table: caption.table)
    }
  }
}

/// Which section the settings show, kept while the app runs: the window opens on the section
/// it was left on, and «Справка» or a test can open one.
@MainActor
@Observable
final class SettingsNavigation {
  static let shared = SettingsNavigation()

  var section: SettingsSection = .general
  var query = ""
}
