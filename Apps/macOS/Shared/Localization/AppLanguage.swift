import AppCore
import Foundation
import Observation
import SwiftUI

/// Interface language.
///
/// The language is switched live rather than only on restart: every string is resolved
/// against an explicitly chosen `.lproj` bundle instead of relying on SwiftUI's own
/// lookup, and the same locale is handed to every number and date formatter. The system
/// menu bar keeps the language macOS gave the process, so Settings also offers a restart.
@MainActor
@Observable
public final class AppLanguage {
  public enum Choice: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case russian = "ru"

    public var settingsKey: String {
      switch self {
      case .system: "settings.language.system"
      case .english: "settings.language.en"
      case .russian: "settings.language.ru"
      }
    }
  }

  private nonisolated static let defaultsKey = "app.language"

  public private(set) var locale: Locale
  public private(set) var bundle: Bundle
  /// Set only on the stand-in a view gets when it is shown without the app's dependencies
  /// (`AppDependencies.missing(in:)`): in Debug every text then names the view, so the
  /// mistake is seen at once instead of a window that quietly does nothing.
  public let missingDependency: String?

  public var choice: Choice {
    didSet {
      guard choice != oldValue else { return }
      Self.store(choice, in: .standard)
      rebuild()
    }
  }

  /// The language the interface had when this object was made — for the app's own, at launch:
  /// macOS draws the menu bar in it until the next launch.
  public let launchCode: String

  /// Whether Settings offers «Перезапустить»: only when a restart would change something —
  /// the language in use is not the one of the menu bar. The same language chosen again, or
  /// the one of the launch chosen back, offers nothing.
  public var needsRestart: Bool { resolvedCode != launchCode }

  /// The key of the app's own domain macOS reads the languages of the process from at launch,
  /// for the menus it draws itself.
  nonisolated static let appleLanguagesKey = "AppleLanguages"

  /// Writes a choice where the next launch reads it: `app.language`, and `AppleLanguages` of
  /// the app's own domain, so the next launch starts in the chosen language, system menus
  /// included. «System» removes that override instead of writing one: the app follows the
  /// Mac again. Writing the resolved language for «System» too pinned the app to whatever an
  /// earlier choice had left there.
  nonisolated static func store(_ choice: Choice, in defaults: UserDefaults) {
    defaults.set(choice.rawValue, forKey: defaultsKey)
    switch choice {
    case .system: defaults.removeObject(forKey: appleLanguagesKey)
    case .english, .russian: defaults.set([choice.rawValue], forKey: appleLanguagesKey)
    }
  }

  /// Once a launch (`AppLaunch`): `AppleLanguages` of the app's domain is made to agree with
  /// the choice stored beside it. «System» chosen before `store` existed left the language of
  /// an earlier choice there, and macOS drew the menus of every later launch in it.
  ///
  /// Only what `domain` itself holds is read, never the arguments of the launch: a UI test
  /// starts the app with `-app.language en`, and that must not become the owner's language.
  /// Nothing is done while no choice was ever made.
  nonisolated static func settle(in defaults: UserDefaults, domain: String) {
    guard let values = defaults.persistentDomain(forName: domain),
      let stored = values[defaultsKey] as? String, let choice = Choice(rawValue: stored)
    else { return }
    let override = values[appleLanguagesKey] as? [String]
    switch choice {
    case .system:
      if override != nil { defaults.removeObject(forKey: appleLanguagesKey) }
    case .english, .russian:
      if override != [choice.rawValue] {
        defaults.set([choice.rawValue], forKey: appleLanguagesKey)
      }
    }
  }

  public init(missingDependency: String? = nil) {
    let choice = Self.storedChoice(in: .standard)
    self.choice = choice
    self.locale = Locale(identifier: Self.code(for: choice))
    self.bundle = Self.bundle(for: Self.code(for: choice))
    self.launchCode = Self.code(for: choice)
    self.missingDependency = missingDependency
  }

  /// Two-letter code actually in use, with `system` resolved against system preferences.
  public var resolvedCode: String { Self.code(for: choice) }

  /// The two-letter code of the interface as the choice stored in `defaults` resolves it —
  /// the rule of `resolvedCode` — for work off the main thread that has to write in the
  /// language of the interface.
  nonisolated static func storedCode(in defaults: UserDefaults) -> String {
    code(for: storedChoice(in: defaults), in: defaults)
  }

  /// The choice stored in `defaults`; «System» when none is, or it is not one of the choices.
  private nonisolated static func storedChoice(in defaults: UserDefaults) -> Choice {
    defaults.string(forKey: defaultsKey).flatMap(Choice.init(rawValue:)) ?? .system
  }

  /// Looks a key up in the chosen language. A key the chosen language lacks is looked up in
  /// the app's own tables — English, the language of development — and a key no table has
  /// comes back as itself, which makes it obvious in the interface instead of silently empty.
  /// The first can never ship: `testEveryEnglishKeyIsTranslatedIntoRussian` walks every table
  /// compiled into the bundle, so a Russian gap fails the tests rather than showing English.
  public func callAsFunction(_ key: String, table: String = "Common") -> String {
    let value = bundle.localizedString(forKey: key, value: nil, table: table)
    return value == key ? Bundle.main.localizedString(forKey: key, value: key, table: table) : value
  }

  /// Convenience for interpolated strings: `language.format("transactions.paidFor", name)`.
  public func format(_ key: String, table: String = "Common", _ arguments: CVarArg...) -> String {
    String(format: callAsFunction(key, table: table), locale: locale, arguments: arguments)
  }

  /// A string whose arguments are all counts (`%lld`): each picks its plural form, and each is
  /// written the way the app writes numbers, «1,250 операций» — a format writes an integer
  /// without grouping.
  public func format(_ key: String, table: String = "Common", counts: Int...) -> String {
    counted(key, table: table, counts)
  }

  func counted(_ key: String, table: String, _ counts: [Int]) -> String {
    let text = String(format: callAsFunction(key, table: table), locale: locale, arguments: counts)
    return NumberText.groupingCounts(counts.map { Int64($0) }, in: text)
  }

  private func rebuild() {
    locale = Locale(identifier: resolvedCode)
    bundle = Self.bundle(for: resolvedCode)
  }

  private nonisolated static func code(
    for choice: Choice, in defaults: UserDefaults = .standard
  ) -> String {
    switch choice {
    case .system:
      let preferred = systemLanguages(in: defaults).first ?? "en"
      return preferred.hasPrefix("ru") ? "ru" : "en"
    case .english:
      return "en"
    case .russian:
      return "ru"
    }
  }

  /// The languages of the Mac itself: its global domain. Not `Locale.preferredLanguages`,
  /// which reads `AppleLanguages` of the app's own domain first — the key an explicit choice
  /// writes — so «System» resolved to the last language chosen by hand. The process's list
  /// is left for a Mac whose global domain says nothing.
  private nonisolated static func systemLanguages(in defaults: UserDefaults) -> [String] {
    let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)
    if let languages = global?[appleLanguagesKey] as? [String], !languages.isEmpty {
      return languages
    }
    return Locale.preferredLanguages
  }

  private static func bundle(for code: String) -> Bundle {
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return .main
    }
    return bundle
  }
}
