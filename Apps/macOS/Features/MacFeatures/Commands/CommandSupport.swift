import AppCore
import Foundation

/// An amount typed into a command: «350», «350.50», «350,50», «1 500». Read as a decimal, never
/// as a floating-point number; anything else is `nil`.
enum CommandAmount {
  static func read(_ text: String) -> Decimal? {
    var plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
    plain.removeAll { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }
    plain = plain.replacingOccurrences(of: ",", with: ".")
    guard !plain.isEmpty, plain.filter({ $0 == "." }).count <= 1,
      plain.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })
    else { return nil }
    return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
  }
}

/// «Скрыть суммы» driven by a Focus filter: the state of the rule (`FocusAmounts`) is kept in
/// `UserDefaults` of this Mac (`privacy.focus`), so the end of a Focus restores what its start
/// changed even across a restart. With the app not running, the switch itself is written to the
/// same key `AmountPrivacy` reads at launch.
@MainActor
enum FocusAmountsSwitch {
  nonisolated static let key = "privacy.focus"

  static func apply(focusHides: Bool, defaults: UserDefaults = .standard) {
    var state =
      defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FocusAmounts.self, from: $0) }
      ?? FocusAmounts()
    let amounts = AppLaunch.startedDependencies?.environment.amounts
    let hiddenNow = amounts?.hidesAmounts ?? defaults.bool(forKey: AmountPrivacy.key)
    let hide = state.apply(focusHides: focusHides, hiddenNow: hiddenNow)
    if let amounts {
      amounts.hidesAmounts = hide
    } else {
      defaults.set(hide, forKey: AmountPrivacy.key)
    }
    if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    AppLog.info(
      "privacy.focusFilter", .ui, "a Focus filter switched the amounts",
      [LogPair("hides", .flag(hide))])
  }
}
