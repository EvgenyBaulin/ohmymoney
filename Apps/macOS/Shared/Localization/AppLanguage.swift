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

    case ukrainian = "uk"
    case belarusian = "be"
    case kazakh = "kk"
    case uzbek = "uz"
    case kyrgyz = "ky"
    case tajik = "tg"
    case armenian = "hy"
    case georgian = "ka"
    case azerbaijani = "az"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguesePortugal = "pt-PT"
    case polish = "pl"
    case czech = "cs"
    case dutch = "nl"
    case turkish = "tr"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case vietnamese = "vi"
    case indonesian = "id"
    case thai = "th"
    case hindi = "hi"
    case portugueseBrazil = "pt-BR"
    case arabic = "ar"
    case hebrew = "he"

    public var settingsKey: String { "settings.language.\(rawValue)" }
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
    default: defaults.set([choice.rawValue], forKey: appleLanguagesKey)
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
    default:
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

  /// Language tag actually in use, with `system` resolved against system preferences.
  public var resolvedCode: String { Self.code(for: choice) }

  /// The language tag of the interface as the choice stored in `defaults` resolves it —
  /// the rule of `resolvedCode` — for work off the main thread that has to write in the
  /// language of the interface.
  nonisolated static func storedCode(in defaults: UserDefaults) -> String {
    code(for: storedChoice(in: defaults), in: defaults)
  }

  /// The choice stored in `defaults`; «System» when none is, or it is not one of the choices.
  private nonisolated static func storedChoice(in defaults: UserDefaults) -> Choice {
    defaults.string(forKey: defaultsKey).flatMap(Choice.init(rawValue:)) ?? .system
  }

  /// Looks up a key in the chosen language, then explicitly in English. A key absent
  /// from both languages comes back as itself so missing source strings remain visible.
  ///
  /// On an iPhone and an iPad a key `x.y` may have a sibling `x.y.touch` (`Self.touchSuffix`):
  /// the same sentence for a screen with no keyboard, which names the «Отменить» button where
  /// the Mac names ⌘Z. The sibling wins there; the Mac never reads it.
  public func callAsFunction(_ key: String, table: String = "Common") -> String {
    #if os(iOS)
      text(key, table: table, forTouch: true)
    #else
      text(key, table: table, forTouch: false)
    #endif
  }

  /// The same lookup for either platform, also used to check both sets of instructions.
  func text(_ key: String, table: String, forTouch: Bool) -> String {
    Self.localizedText(
      key, table: table, forTouch: forTouch, in: bundle, fallback: Self.englishBundle)
  }

  /// A touch instruction falls back to its English touch version before a Mac instruction.
  /// This keeps keyboard shortcuts out of instructions on devices without a keyboard.
  nonisolated static func localizedText(
    _ key: String, table: String, forTouch: Bool, in selected: Bundle, fallback: Bundle
  ) -> String {
    if forTouch, !key.hasSuffix(touchSuffix) {
      let touchKey = key + touchSuffix
      for source in [selected, fallback] {
        let value = source.localizedString(forKey: touchKey, value: nil, table: table)
        if value != touchKey { return value }
      }
    }
    for source in [selected, fallback] {
      let value = source.localizedString(forKey: key, value: nil, table: table)
      if value != key { return value }
    }
    return key
  }

  /// The ending of a key that words an instruction for a touch screen (see `callAsFunction`).
  public static let touchSuffix = ".touch"

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

  nonisolated static func code(
    for choice: Choice, in defaults: UserDefaults = .standard
  ) -> String {
    choice == .system
      ? systemCode(for: systemLanguages(in: defaults).first ?? "en") : choice.rawValue
  }

  /// Uses the same regional and script matching as first-launch data. Only the first
  /// system language counts; an unsupported one uses English rather than a later preference.
  nonisolated static func systemCode(for identifier: String) -> String {
    StarterLanguage(identifier: identifier).rawValue
  }

  public var layoutDirection: LayoutDirection {
    ["ar", "he"].contains(resolvedCode) ? .rightToLeft : .leftToRight
  }

  public var translationVerification: TranslationVerification {
    StarterLanguage(identifier: resolvedCode).translationVerification
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

  private static var englishBundle: Bundle {
    localizedBundle(for: "en") ?? .main
  }

  private static func bundle(for code: String) -> Bundle {
    localizedBundle(for: code) ?? englishBundle
  }

  private static func localizedBundle(for code: String) -> Bundle? {
    Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
  }
}
