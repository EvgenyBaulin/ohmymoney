import AppCore
import SwiftUI
import TipKit

/// Short tips on the spot (TipKit): at the first visit of a screen, one beside the control that
/// matters, each once. «Больше не показывать подсказки» in Settings → General turns them all off.
/// Their memory is TipKit's own, on this Mac.
enum GuideTips {
  /// Off in the settings: every tip's rule asks for it.
  @Parameter static var enabled: Bool = true

  /// At launch, outside the test host: the tips' store, and the switch of the settings.
  @MainActor
  static func configure() {
    guard !AppEnvironment.isTestHost else { return }
    enabled = !GuideStore.shared.tipsOff
    try? Tips.configure([.displayFrequency(.immediate)])
  }

  @MainActor
  static func setOff(_ off: Bool) {
    GuideStore.shared.tipsOff = off
    enabled = !off
  }

  /// The language of the interface, read the way the app stores it: a tip is drawn outside the
  /// app's environment.
  static var russian: Bool { AppLanguage.storedCode(in: .standard).hasPrefix("ru") }
}

extension Text {
  /// The words of a tip as easy to read as the rest: the primary colour at the size of a callout,
  /// not the small grey TipKit gives a message by default.
  fileprivate func readableTip() -> Text {
    font(.callout).foregroundStyle(.primary)
  }
}

/// The entry line: «кофе 300» and Return.
struct EntryLineTip: Tip {
  var title: Text {
    Text(
      verbatim: GuideText("Запишите трату одной строкой", "Write an expense in one line")
        .text(russian: GuideTips.russian))
  }
  var message: Text? {
    Text(
      verbatim: GuideText(
        "Например, «кофе 300» и Return. Tab открывает все поля.",
        "For example «coffee 300» and Return. Tab opens every field."
      ).text(russian: GuideTips.russian)
    )
    .readableTip()
  }
  var image: Image? { Image(systemName: "text.cursor") }
  var rules: [Rule] { #Rule(GuideTips.$enabled) { $0 } }
  var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// The search of «Операции». The name is the one of «Траты», whose search it was: the tip
/// shown there once is not shown again.
struct SpendingSearchTip: Tip {
  var title: Text {
    Text(
      verbatim: GuideText("Поиск по всей истории", "Search the whole history")
        .text(russian: GuideTips.russian))
  }
  var message: Text? {
    Text(
      verbatim: GuideText(
        "Слова операции, категория, место, счёт или сумма. Фильтры — кнопка рядом.",
        "Words of an operation, a category, a place, an account or an amount. Filters are next to it."
      ).text(russian: GuideTips.russian)
    )
    .readableTip()
  }
  var image: Image? { Image(systemName: "magnifyingglass") }
  var rules: [Rule] { #Rule(GuideTips.$enabled) { $0 } }
  var options: [any TipOption] { [MaxDisplayCount(1)] }
}
