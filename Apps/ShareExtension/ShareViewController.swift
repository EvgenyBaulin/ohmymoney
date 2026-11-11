import AppCore
import SwiftUI

#if os(macOS)
  import AppKit

  final class ShareViewController: NSViewController {
    override func loadView() {
      let host = NSHostingController(rootView: ShareComposeView(context: extensionContext))
      addChild(host)
      view = host.view
      preferredContentSize = NSSize(width: 360, height: 220)
    }
  }
#else
  import UIKit

  final class ShareViewController: UIViewController {
    override func viewDidLoad() {
      super.viewDidLoad()
      let host = UIHostingController(rootView: ShareComposeView(context: extensionContext))
      addChild(host)
      host.view.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        host.view.topAnchor.constraint(equalTo: view.topAnchor),
        host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      host.didMove(toParent: self)
    }
  }
#endif

private struct ShareComposeView: View {
  let context: NSExtensionContext?
  @State private var status = "share.preparing"
  @State private var finished = false

  var body: some View {
    VStack(spacing: 16) {
      Text("OhMyMoney")
      Text(verbatim: String(localized: String.LocalizationValue(status), table: "ShareImport"))
        .multilineTextAlignment(.center)
      if !finished { ProgressView() }
      Button {
        context?.completeRequest(returningItems: nil)
      } label: {
        Text("share.close", tableName: "ShareImport")
      }
    }
    .padding(24)
    .task { await prepare() }
  }

  @MainActor
  private func prepare() async {
    guard let inbox = ShareInbox.configured() else {
      status = "share.unavailable"
      finished = true
      return
    }
    let inputs = context?.inputItems as? [NSExtensionItem] ?? []
    guard !inputs.isEmpty else {
      status = "share.unsupported"
      finished = true
      return
    }
    // Publish one item at a time to keep peak memory bounded to one photo or PDF. Each
    // published file survives the extension being terminated before the next one is saved.
    var written: [URL] = []
    do {
      for input in inputs {
        if let text = try SharedItemProviderReader.fallbackText(in: input) {
          written.append(try inbox.enqueue(text))
        }
        for provider in input.attachments ?? [] {
          let item = try await SharedItemProviderReader.read(provider)
          written.append(try inbox.enqueue(item))
        }
      }
      status = written.isEmpty ? "share.unsupported" : "share.saved"
    } catch {
      status = written.isEmpty ? "share.failed" : "share.partial"
    }
    finished = true
  }

}
