import AppCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// Whether the recovery sheet of a key was shown, kept on this device by the key's fingerprint
/// (never the key): the sheet is shown once, for printing, and the settings say so afterwards.
enum RecoverySheetMark {
  static let key = "sync.recoveryShown"

  static func wasShown(_ key: SyncKey, in defaults: UserDefaults) -> Bool {
    defaults.string(forKey: Self.key) == key.fingerprint
  }

  static func markShown(_ key: SyncKey, in defaults: UserDefaults) {
    defaults.set(key.fingerprint, forKey: Self.key)
  }
}

/// The QR code of the recovery sheet: the 24 words, spaced, as text.
enum RecoveryQR {
  static func image(for words: [String], scale: CGFloat = 8) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(words.joined(separator: " ").utf8)
    filter.correctionLevel = "M"
    guard
      let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}

/// One sheet of paper: the QR code and the 24 words, numbered, in three columns. What is on it
/// is the key itself — whoever holds the sheet can read the exchange's files.
struct RecoveryPage: View {
  @Dependency(\.environment) private var environment
  let key: SyncKey

  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  var body: some View {
    let words = key.recoveryWords
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("recovery.page.title")).appFont(.title2.weight(.semibold))
      Text(verbatim: t("recovery.page.hint")).appFont(.callout)
      HStack(alignment: .top, spacing: 20) {
        if let image = RecoveryQR.image(for: words) {
          Image(decorative: image, scale: 2)
            .interpolation(.none)
            .resizable()
            .frame(width: 160, height: 160)
            .accessibilityLabel(Text(verbatim: t("recovery.page.qr")))
        }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
          ForEach(0..<8, id: \.self) { row in
            GridRow {
              ForEach(0..<3, id: \.self) { column in
                let index = column * 8 + row
                Text(verbatim: "\(index + 1). \(words[index])")
                  .appFont(.body.monospaced())
              }
            }
          }
        }
      }
      Text(
        verbatim: environment.format(
          "recovery.page.fingerprint", table: "SyncHistory", key.fingerprint)
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(24)
  }
}

/// «Лист восстановления»: shown once, to print or write down; then the settings only say that
/// it was shown.
struct RecoveryKeySheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let key: SyncKey
  let shown: () -> Void

  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      RecoveryPage(key: key)
      Label {
        Text(verbatim: t("recovery.sheet.once"))
      } icon: {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      .appFont(.callout)
      HStack {
        #if canImport(AppKit)
          Button(t("recovery.sheet.print")) { print() }
            .accessibilityIdentifier("recovery.print")
        #endif
        Spacer()
        Button(t("recovery.sheet.done")) {
          shown()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("recovery.done")
      }
    }
    .padding(20)
    .sheetFrame(width: 640, height: 520)
  }

  #if canImport(AppKit)
    private func print() {
      let page = NSHostingView(
        rootView: RecoveryPage(key: key).handingOver(dependencies)
          .frame(width: 540, height: 420).background(Color.white).environment(\.colorScheme, .light)
      )
      page.frame = NSRect(x: 0, y: 0, width: 540, height: 420)
      let operation = NSPrintOperation(view: page)
      operation.printInfo.horizontalPagination = .fit
      operation.printInfo.verticalPagination = .fit
      operation.run()
    }
  #endif
}

/// «Ключ синхронизации» in the settings of the exchange: make the key and show its sheet once;
/// afterwards, only the fingerprint and «Новый ключ…».
struct SyncKeySection: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  var store: any SyncKeyStoring = KeychainSyncKeyStore()
  var defaults: UserDefaults = .standard

  @State private var key: SyncKey?
  @State private var showing: SyncKey?
  @State private var confirmsNew = false
  @State private var failed = false
  @State private var recoveryWords = ""

  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  var body: some View {
    Section {
      if let key {
        Text(
          verbatim: environment.format("recovery.key.made", table: "SyncHistory", key.fingerprint)
        )
        if RecoverySheetMark.wasShown(key, in: defaults) {
          Text(verbatim: t("recovery.key.shown")).appFont(.caption).foregroundStyle(.secondary)
        } else {
          Button(t("recovery.key.show")) { showing = key }
            .accessibilityIdentifier("recovery.show")
        }
        Button(t("recovery.key.new")) { confirmsNew = true }
      } else {
        Text(verbatim: t("recovery.key.none")).foregroundStyle(.secondary)
        Button(t("recovery.key.make")) { make(replacing: false) }
          .accessibilityIdentifier("recovery.make")
      }
      if failed {
        Text(verbatim: t("recovery.key.failed")).appFont(.caption).foregroundStyle(.red)
      }
      SecureField(t("recovery.key.words"), text: $recoveryWords)
        .accessibilityIdentifier("recovery.words")
      Button(t("recovery.key.restore")) { restore() }
        .disabled(recoveryWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("recovery.restore")
    } header: {
      Text(verbatim: t("recovery.key.header"))
    } footer: {
      Text(verbatim: t("recovery.key.hint")).foregroundStyle(.secondary)
    }
    .task { key = store.load() }
    .onChange(of: environment.sync?.status) { _, _ in key = store.load() }
    .disabled(environment.sync?.isUsingPayloadKey == true)
    .confirmationDialog(
      t("recovery.key.newTitle"), isPresented: $confirmsNew, titleVisibility: .visible
    ) {
      Button(t("recovery.key.newConfirm"), role: .destructive) { make(replacing: true) }
    } message: {
      Text(verbatim: t("recovery.key.newMessage"))
    }
    .sheet(item: $showing) { shown in
      RecoveryKeySheet(key: shown) { RecoverySheetMark.markShown(shown, in: defaults) }
        .handingOver(dependencies)
    }
  }

  private func make(replacing: Bool) {
    guard environment.sync?.isUsingPayloadKey != true else { return }
    do {
      let made: SyncKey
      if replacing {
        made = SyncKey.generate()
        try store.save(made)
      } else {
        made = try store.keyCreatingIfNeeded().key
      }
      key = made
      if replacing { defaults.set(true, forKey: SyncWiring.replacedKey) }
      failed = false
      showing = made
      AppLog.info("sync.keyMade", .db, "a sync key was made", [LogPair("new", .flag(replacing))])
      if replacing { Task { await environment.sync?.retry() } }
    } catch {
      failed = true
      AppLog.warning(
        "sync.keyNotSaved", .db, "the sync key was not kept", [LogPair("error", .error(error))])
    }
  }

  private func restore() {
    guard environment.sync?.isUsingPayloadKey != true else { return }
    do {
      try store.recover(from: recoveryWords)
      key = store.load()
      recoveryWords = ""
      failed = false
      Task { await environment.sync?.retry() }
    } catch {
      failed = true
    }
  }
}

extension SyncKey: @retroactive Identifiable {
  public var id: String { fingerprint }
}
