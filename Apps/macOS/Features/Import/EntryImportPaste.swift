#if os(macOS)
  import AppKit
  import SwiftUI
  import UniformTypeIdentifiers

  /// The text field's AppKit editor owns Paste while it is editing. Intercept attachment
  /// keystrokes before the editor, and leave ordinary text to its selection and SMS handling.
  struct EntryImportPaste: NSViewRepresentable {
    let environment: AppEnvironment
    let focused: Bool

    func makeNSView(context: Context) -> Receiver {
      Receiver(environment: environment, focused: focused)
    }

    func updateNSView(_ view: Receiver, context: Context) { view.focused = focused }

    static func dismantleNSView(_ view: Receiver, coordinator: ()) { view.stop() }

    final class Receiver: NSView {
      let environment: AppEnvironment
      var focused: Bool
      private var monitor: Any?

      init(environment: AppEnvironment, focused: Bool) {
        self.environment = environment
        self.focused = focused
        super.init(frame: .zero)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          let handled = MainActor.assumeIsolated {
            self?.receive(event, pasteboard: .general) == true
          }
          return handled ? nil : event
        }
      }

      required init?(coder: NSCoder) { nil }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      static func isPaste(_ event: NSEvent) -> Bool {
        !event.isARepeat
          && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
          && (event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v")
      }

      @discardableResult
      func receive(_ event: NSEvent, pasteboard: NSPasteboard) -> Bool {
        guard focused, window != nil, event.window === window, Self.isPaste(event),
          EntryImportReceiving.isAllowed(environment)
        else { return false }
        let sources = EntryImportPasteboard.sources(in: pasteboard)
        guard !sources.isEmpty else { return false }
        environment.entryImports.append(sources)
        return true
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }
    }
  }

  @MainActor
  enum EntryImportPasteboard {
    static func sources(in pasteboard: NSPasteboard) -> [EntryImportSource] {
      let urls =
        pasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      if !urls.isEmpty { return urls.map { EntryImportSource(url: $0) } }
      return (pasteboard.pasteboardItems ?? []).compactMap { item in
        // Prefer a PDF to its preview. Preserve the bytes and their real media type.
        let type =
          item.types.first { UTType($0.rawValue)?.conforms(to: .pdf) == true }
          ?? item.types.first { UTType($0.rawValue)?.conforms(to: .image) == true }
        guard let type, let data = item.data(forType: type) else { return nil }
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
        return EntryImportSource(file: EntryImportFile(data: data, filename: "import.\(ext)"))
      }
    }
  }
#endif
