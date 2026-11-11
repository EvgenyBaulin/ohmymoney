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
    let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap {
      $0.attachments ?? []
    }
    guard !providers.isEmpty else {
      status = "share.unsupported"
      finished = true
      return
    }
    // Decode every provider before publishing any item. Each published file is durable even
    // when the extension is terminated before the next one can be saved.
    var written: [URL] = []
    do {
      let items = try await readAll(providers)
      for item in items { written.append(try inbox.enqueue(item)) }
      status = "share.saved"
    } catch {
      status = written.isEmpty ? "share.failed" : "share.partial"
    }
    finished = true
  }

  @MainActor
  private func readAll(_ providers: [NSItemProvider]) async throws -> [SharedImportItem] {
    var items: [SharedImportItem] = []
    for provider in providers { items.append(try await SharedItemProviderReader.read(provider)) }
    return items
  }
}
