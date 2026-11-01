import AppCore
import AppKit
import QuickLookUI

/// The preview of an archive of OhMyMoney in Finder (space bar): the day it was made, the
/// version that made it and how many operations it carries — read from the open manifest at the
/// start of the file — or «Зашифровано» for a file with a password, whose contents nothing but
/// the app and the password can open. The file is never read whole and never changed.
final class ArchivePreviewController: NSViewController, QLPreviewingController {
  private let stack = NSStackView()

  override func loadView() {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    view = stack
    preferredContentSize = NSSize(width: 420, height: 180)
  }

  func preparePreviewOfFile(at url: URL) async throws {
    let text = ArchivePreviewText.make(
      ArchivePreviewText.peek(at: url), locale: .current,
      text: { Bundle.main.localizedString(forKey: $0, value: nil, table: "MacFeatures") })
    await MainActor.run { self.show(text) }
  }

  @MainActor
  private func show(_ text: ArchivePreviewText) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let title = NSTextField(labelWithString: text.title)
    title.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 4)
    stack.addArrangedSubview(title)
    for line in text.lines {
      let label = NSTextField(wrappingLabelWithString: line)
      label.textColor = .secondaryLabelColor
      stack.addArrangedSubview(label)
    }
  }
}
