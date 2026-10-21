import AppKit
import SwiftUI

/// «О программе»: the standard About panel of macOS — name, version, copyright — with one line
/// of credits under them, «Нравится OhMyMoney? Поддержать автора →», a link the default browser
/// opens. The panel's own text view follows the link; nothing is loaded in the app, and nothing
/// is sent anywhere until the owner clicks.
@MainActor
enum AboutPanel {
  /// The author's page for support.
  static let supportURL = URL(string: "https://pay.cloudtips.ru/p/4b507463")!

  /// The credits line in the interface language: the question plain, the call a link.
  static func credits(_ language: AppLanguage) -> NSAttributedString {
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let text = NSMutableAttributedString(
      string: language("about.support.question") + " ",
      attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: centred])
    text.append(
      NSAttributedString(
        string: language("about.support.link"),
        attributes: [.font: font, .link: supportURL, .paragraphStyle: centred]))
    return text
  }

  /// «Благодарности»: each library with its version and the terms it is given under.
  static func acknowledgements(_ language: AppLanguage) -> NSAttributedString {
    let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 2)
    let heading = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
    let text = NSMutableAttributedString(
      string: language("about.acknowledgements") + "\n",
      attributes: [.font: heading, .foregroundColor: NSColor.labelColor])
    for library in Licenses.all {
      text.append(
        NSAttributedString(
          string: "\n\(library.name) \(library.version) — MIT\n\(library.license)\n",
          attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
    }
    return text
  }

  /// The credits and the acknowledgements under them: what the panel shows.
  static func panelText(_ language: AppLanguage) -> NSAttributedString {
    let text = NSMutableAttributedString(attributedString: credits(language))
    text.append(NSAttributedString(string: "\n\n"))
    text.append(acknowledgements(language))
    return text
  }

  static func show(_ language: AppLanguage) {
    NSApp.orderFrontStandardAboutPanel(options: [.credits: panelText(language)])
    NSApp.activate()
  }
}

/// The About item of the application menu, opening the panel with the credits.
struct AboutCommands: Commands {
  let environment: AppEnvironment

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button(environment.language("about.menu")) { AboutPanel.show(environment.language) }
    }
  }
}
