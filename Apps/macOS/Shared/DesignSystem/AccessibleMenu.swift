import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// An ordinary menu with an explicit, actionable trigger. Some SwiftUI Menu styles export
/// a menu-button AX node without a press action on macOS; a native NSButton owns that action.
struct AccessibleMenu<Content: View>: View {
  let title: String
  let symbol: String
  let identifier: String
  let showsTitle: Bool
  let tint: Color?
  let content: Content
  @Environment(\.dependencies) private var dependencies
  @Environment(\.isEnabled) private var isEnabled

  init(
    _ title: String, systemImage: String, identifier: String, showsTitle: Bool = false,
    tint: Color? = nil, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    symbol = systemImage
    self.identifier = identifier
    self.showsTitle = showsTitle
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    #if os(macOS)
      NativeMenuButton(
        title: title, symbol: symbol, identifier: identifier, showsTitle: showsTitle,
        tint: tint, isEnabled: isEnabled, content: AnyView(content.handingOver(dependencies))
      )
      .fixedSize()
    #else
      Menu {
        content
      } label: {
        if showsTitle {
          Label(title, systemImage: symbol)
        } else {
          Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
      }
      .accessibilityIdentifier(identifier)
    #endif
  }
}

#if os(macOS)
  private struct NativeMenuButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let identifier: String
    let showsTitle: Bool
    let tint: Color?
    let isEnabled: Bool
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
      let button = MenuTriggerButton()
      button.isBordered = false
      button.setAccessibilityElement(true)
      button.setAccessibilityChildrenInNavigationOrder([])
      button.target = context.coordinator
      button.action = #selector(Coordinator.openMenu(_:))
      updateNSView(button, context: context)
      return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
      button.title = showsTitle ? title : ""
      // The symbol is decorative. The button itself owns the title and press action.
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = showsTitle ? .imageLeading : .imageOnly
      button.contentTintColor = tint.map { NSColor($0) }
      button.isEnabled = isEnabled
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.setAccessibilityIdentifier(identifier)
      context.coordinator.content = content
    }

    @MainActor
    final class Coordinator: NSObject {
      var content = AnyView(EmptyView())

      @objc func openMenu(_ sender: NSButton) {
        let menu = NSHostingMenu(rootView: content)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
      }
    }
  }

  /// A menu trigger is one AX leaf. Exporting an image/cell beneath the representable can
  /// give it a different AX parent from the one AppKit reports to the audit.
  private final class MenuTriggerButton: NSButton {
    override func accessibilityChildren() -> [Any]? { [] }
  }
#endif
