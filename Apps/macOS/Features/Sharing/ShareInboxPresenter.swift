import AppCore
import SwiftUI

extension View {
  func shareInbox(_ deps: AppDependencies) -> some View {
    modifier(ShareInboxPresenter(deps: deps))
  }
}

/// One shared file at a time, after unlock and startup. A file stays in the inbox until the
/// owner closes its sheet; a crash or a lock leaves it available on the next launch.
@MainActor
private struct ShareInboxPresenter: ViewModifier {
  let deps: AppDependencies
  @Environment(\.scenePhase) private var phase
  @State private var request: Request?
  @State private var offeredFile: URL?
  @State private var shouldConsume = true
  private let session = ShareInboxSession.shared

  private struct Request: Identifiable {
    let id: URL
    let item: SharedImportItem?
  }

  private var canPresent: Bool {
    ShareInbox.isEnabled && phase == .active && !deps.environment.lock.isCovered
      && deps.environment.state == .ready && deps.compute.wholeSnapshot != nil
      && deps.environment.receiptRequest == nil && deps.environment.statementImportRequest == nil
      && AppPaths.dataSet == nil && !AppEnvironment.isTestHost && offeredFile == nil
      && session.file == nil
  }

  func body(content: Content) -> some View {
    content
      .task(id: canPresent) {
        guard canPresent, let inbox = ShareInbox.configured(),
          let file = try? session.claimNext(in: inbox)
        else { return }
        offeredFile = file
        let item = try? inbox.read(file)
        shouldConsume = item != nil
        request = Request(id: file, item: item)
      }
      .onDisappear {
        if let file = offeredFile { session.release(file) }
      }
      .sheet(item: deps.environment.lock.presenting($request), onDismiss: acknowledge) { request in
        if let item = request.item {
          if item.kind == .text, let text = item.text {
            SharedMessageSheet(text: text, deps: deps).appDependencies(deps)
          } else {
            ReceiptSheet(
              urls: [], sharedPhoto: ReceiptPhoto(data: item.data, filename: item.filename)
            )
            .appDependencies(deps)
          }
        } else {
          SharedImportFailure(deps: deps).appDependencies(deps)
        }
      }
  }

  private func acknowledge() {
    // Closing sheets for the lock is not an acknowledgement by the owner.
    guard !deps.environment.lock.isCovered else {
      request = nil
      if let file = offeredFile { session.release(file) }
      offeredFile = nil
      return
    }
    if let file = offeredFile {
      if shouldConsume, let inbox = ShareInbox.configured() {
        do {
          try inbox.acknowledge(file)
          session.release(file)
        } catch {
          session.postpone(file)
        }
      } else {
        session.postpone(file)
      }
    }
    offeredFile = nil
  }
}

private struct SharedMessageSheet: View {
  let text: String
  let deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @State private var result: String?

  private func t(_ key: String) -> String {
    deps.environment.language(key, table: key.hasPrefix("share.") ? "ShareImport" : "AutoEntry")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: t("share.messageTitle")).appFont(.headline)
      if let result {
        Text(verbatim: t(result)).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(verbatim: t("share.messageHint"))
          .fixedSize(horizontal: false, vertical: true)
        ScrollView { Text(verbatim: text).textSelection(.enabled) }
      }
      HStack {
        Button(t("share.close")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if result == nil {
          Button(t("share.saveDraft")) { result = SharedTextImport.propose(text, deps: deps) }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 360, idealWidth: 480, minHeight: 260, idealHeight: 340)
  }
}

private struct SharedImportFailure: View {
  let deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 16) {
      Text(verbatim: deps.environment.language("share.damaged", table: "ShareImport"))
      Button(deps.environment.language("share.close", table: "ShareImport")) { dismiss() }
    }.padding(20)
  }
}
