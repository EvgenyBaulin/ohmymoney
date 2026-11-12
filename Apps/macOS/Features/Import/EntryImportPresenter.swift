import AppCore
import SwiftUI
import UniformTypeIdentifiers

extension View {
  func entryImportSheet(_ deps: AppDependencies) -> some View {
    modifier(EntryImportPresenter(deps: deps))
  }

  func entryImportDrop(_ environment: AppEnvironment) -> some View {
    modifier(EntryImportDrop(environment: environment))
  }

  @ViewBuilder
  func entryImportPaste(_ environment: AppEnvironment, focused: Bool) -> some View {
    #if os(macOS)
      onPasteCommand(of: EntryImportProvider.types) { providers in
        EntryImportReceiving.receive(providers, environment: environment)
      }
      .background(EntryImportPaste(environment: environment, focused: focused))
    #else
      self
    #endif
  }
}

@MainActor
enum EntryImportReceiving {
  static func isAllowed(_ environment: AppEnvironment) -> Bool {
    environment.state == .ready && !environment.lock.isCovered && !environment.shield.isReadOnly
  }

  static func receive(_ providers: [NSItemProvider], environment: AppEnvironment) {
    guard isAllowed(environment) else { return }
    Task {
      var sources: [EntryImportSource] = []
      for provider in providers {
        // A failed read is visible in the queue, rather than silently disappearing.
        sources.append((try? await EntryImportProvider.read(provider)) ?? EntryImportSource())
      }
      // A lock while a provider is loading covers the queued sheet until unlock.
      guard environment.state == .ready else { return }
      environment.entryImports.append(sources)
    }
  }
}

private struct EntryImportDrop: ViewModifier {
  let environment: AppEnvironment
  @State private var targeted = false

  func body(content: Content) -> some View {
    content
      .onDrop(of: EntryImportProvider.types, isTargeted: $targeted) { providers in
        guard EntryImportReceiving.isAllowed(environment) else { return false }
        EntryImportReceiving.receive(providers, environment: environment)
        return true
      }
      .overlay {
        if targeted && EntryImportReceiving.isAllowed(environment) {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
  }
}

private struct EntryImportPresenter: ViewModifier {
  let deps: AppDependencies

  func body(content: Content) -> some View {
    let environment = deps.environment
    let queue = environment.entryImports
    content
      .sheet(
        item: environment.lock.presenting(Bindable(queue).active),
        onDismiss: { queue.didDismiss(isCovered: environment.lock.isCovered) }
      ) { source in
        EntryImportFlow(source: source).appDependencies(deps)
      }
      .entryImportDrop(environment)
  }
}

/// Resolves a file using the existing readers, then hands the original bytes to the existing
/// flow. No temporary copies or writes to the books are needed to decide where it belongs.
private struct EntryImportFlow: View {
  let source: EntryImportSource
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @State private var file: EntryImportFile?
  @State private var route: Route?

  private enum Route: Equatable { case statement, spreadsheet, receipt, screenshot, choose, failed }

  var body: some View {
    Group {
      if let file, let route {
        switch route {
        case .statement: StatementImportFlow(urls: [], importedFile: file).handingOver(dependencies)
        case .spreadsheet: MigrationFlow(importedFile: file).handingOver(dependencies)
        case .receipt:
          ReceiptSheet(
            urls: [], sharedPhoto: ReceiptPhoto(data: file.data, filename: file.filename)
          ).handingOver(dependencies)
        case .screenshot:
          ScreenshotOperationSheet(data: file.data) { id in
            dismiss()
            OperationReveal.ask(id)
          }.handingOver(dependencies)
        case .choose: choice(file)
        case .failed: failure
        }
      } else if route == .failed {
        failure
      } else {
        ProgressView().padding(40)
      }
    }
    .task { await resolve() }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Import") }

  private func choice(_ file: EntryImportFile) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: t("import.attachment.kind")).appFont(.headline)
      Text(verbatim: file.filename).lineLimit(2)
      Text(verbatim: t("import.attachment.chooseHint"))
        .appFont(.callout).foregroundStyle(.secondary)
      Button(t("import.attachment.statement")) { route = .statement }
      Button(t("import.attachment.receipt")) { route = .receipt }
      Button(t("import.attachment.screenshot")) { route = .screenshot }
      Button(environment.language("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
    }
    .padding(20)
    .sheetFrame(minWidth: 340, idealWidth: 420, minHeight: 240, idealHeight: 280)
    .accessibilityIdentifier("entry.import.choose")
  }

  private var failure: some View {
    VStack(spacing: 16) {
      Text(verbatim: t("import.attachment.failed"))
      Button(t("import.close")) { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding(20)
  }

  private func resolve() async {
    guard file == nil, route == nil else { return }
    let loaded: EntryImportFile?
    if let supplied = source.file {
      loaded = supplied
    } else if let url = source.url, url.isFileURL {
      loaded = await Task.detached(priority: .userInitiated) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? Data(contentsOf: url)).map {
          EntryImportFile(data: $0, filename: url.lastPathComponent)
        }
      }.value
    } else {
      loaded = nil
    }
    guard let loaded, let kind = EntryImportFileKind.of(loaded.filename) else {
      route = .failed
      return
    }
    file = loaded
    switch kind {
    case .statement: route = .statement
    case .spreadsheet: route = .spreadsheet
    case .document:
      let today = environment.today
      let owned = (try? environment.statementImports?.profiles()) ?? []
      let result = await Task.detached(priority: .userInitiated) {
        let isPDF = loaded.data.starts(with: Data("%PDF-".utf8))
        let text = isPDF ? StatementPDFText.lines(from: loaded.data) : []
        let statement: Bool
        if case .parsed = StatementImporter.parsePDFText(
          text, profiles: StatementProfiles.all + owned)
        {
          statement = isPDF
        } else {
          statement = false
        }
        if statement { return ImportDocumentRoute.statement }
        let qr = ReceiptQRDetector.reading(ofFile: loaded.data)
        if case .receipt = qr { return ImportDocumentRoute.receipt }
        let lines = ReceiptTextReader.lines(inFile: loaded.data)
        return ImportDocumentRoute.read(
          lines: lines, today: today, hasReceiptQR: false, isStatement: false)
      }.value
      switch result {
      case .statement: route = .statement
      case .receipt: route = .receipt
      case .screenshot: route = .screenshot
      case .unknown: route = .choose
      }
    }
  }
}
