import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// Files that carry the owner's data, ready to be handed to a file exporter: one CSV, or a folder
/// of them. Before they go, the owner is warned and asked «Зашифровать» (on every time,
/// `EncryptedExportForm`); locked, they go as one file of the archive's container instead.
struct PersonalDataExport: Equatable, Sendable {
  struct File: Equatable, Sendable {
    var name: String
    var data: Data
  }

  /// The name offered, without an extension.
  var defaultName: String
  var files: [File]

  /// One file is exported as itself, several as a folder named `defaultName`.
  var isFolder: Bool { files.count != 1 }

  var document: PersonalDataDocument { PersonalDataDocument(self) }
  var contentType: UTType { isFolder ? .folder : .commaSeparatedText }

  /// What the exporter is handed once the owner answered.
  struct Prepared: Sendable {
    var document: PersonalDataDocument
    var contentType: UTType
    var defaultName: String
  }

  /// The files as they are for `.plain`; for `.locked`, one locked file, sealed and read back
  /// with the password away from the main thread (the key derivation takes seconds).
  func prepared(
    for answer: EncryptedExportForm.Answer, appVersion: String, schemaVersion: Int,
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations
  ) async throws -> Prepared {
    switch answer {
    case .plain:
      return Prepared(document: document, contentType: contentType, defaultName: defaultName)
    case .locked(let password):
      let files = files
      let data = try await Task.detached(priority: .userInitiated) {
        try EncryptedExport.lockedData(
          files, password: password, appVersion: appVersion, schemaVersion: schemaVersion,
          cipher: cipher, iterations: iterations)
      }.value
      return Prepared(
        document: PersonalDataDocument(locked: data), contentType: EncryptedExport.contentType,
        defaultName: defaultName)
    }
  }
}

/// The document the exporter writes: a CSV file, a folder of them, or one locked file.
struct PersonalDataDocument: FileDocument, Sendable {
  enum Payload: Equatable, Sendable {
    case plain(PersonalDataExport)
    case locked(Data)
  }

  static var readableContentTypes: [UTType] {
    [.commaSeparatedText, .folder, EncryptedExport.contentType]
  }
  static var writableContentTypes: [UTType] { readableContentTypes }

  let payload: Payload

  init(_ export: PersonalDataExport) { payload = .plain(export) }
  init(locked data: Data) { payload = .locked(data) }

  init(configuration: ReadConfiguration) throws {
    // Nothing of the app opens these files; the type is only here to be written.
    throw CocoaError(.fileReadUnsupportedScheme)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    switch payload {
    case .locked(let data):
      return FileWrapper(regularFileWithContents: data)
    case .plain(let export):
      if !export.isFolder, let file = export.files.first {
        return FileWrapper(regularFileWithContents: file.data)
      }
      var children: [String: FileWrapper] = [:]
      for file in export.files {
        children[file.name] = FileWrapper(regularFileWithContents: file.data)
      }
      return FileWrapper(directoryWithFileWrappers: children)
    }
  }
}

extension View {
  /// Says that the files carry personal data and asks «Зашифровать» (on) with the password twice,
  /// then offers the CSV — or, locked, one file — to the file exporter. `request` is set by the
  /// button; it goes back to nil when the owner declined or the exporter is done.
  func exportsPersonalData(
    _ request: Binding<PersonalDataExport?>, environment: AppEnvironment,
    onFinished: @escaping (Result<URL, any Error>?) -> Void = { _ in }
  ) -> some View {
    modifier(
      PersonalDataExporter(request: request, environment: environment, onFinished: onFinished))
  }
}

private struct PersonalDataExporter: ViewModifier {
  @Binding var request: PersonalDataExport?
  let environment: AppEnvironment
  let onFinished: (Result<URL, any Error>?) -> Void
  /// The phone's sheet with the warning, the box and the fields.
  @State private var asking = false
  @State private var form = EncryptedExportForm()
  @State private var working = false
  @State private var prepared: PersonalDataExport.Prepared?
  @State private var exporting = false
  /// A lock that failed on the phone, told once its sheet is gone.
  @State private var failure: (any Error)?

  func body(content: Content) -> some View {
    content
      .onChange(of: request) { _, now in
        guard now != nil, prepared == nil, !exporting else { return }
        form.reset()
        #if os(macOS)
          // The Mac asks in a dialog, as its other exports do; after the view has settled.
          Task { @MainActor in
            guard let answer = EncryptedExportPrompt.ask(environment) else {
              request = nil
              return
            }
            await prepare(answer)
          }
        #else
          asking = true
        #endif
      }
      .sheet(
        isPresented: $asking,
        onDismiss: {
          // The exporter and a failure wait for the sheet to be gone: the phone shows nothing over
          // a sheet that is still going away.
          if prepared != nil {
            exporting = true
          } else if let failure {
            self.failure = nil
            onFinished(.failure(failure))
          } else if !working {
            // Swiped away or cancelled: nothing goes, and the password is forgotten.
            request = nil
            form.reset()
          }
        }
      ) {
        EncryptedExportSheet(
          form: $form, working: working, environment: environment,
          cancel: { asking = false },
          export: {
            guard let answer = form.answer else { return }
            Task { @MainActor in await prepare(answer) }
          })
      }
      .fileExporter(
        isPresented: $exporting,
        document: prepared?.document,
        contentType: prepared?.contentType ?? .commaSeparatedText,
        defaultFilename: prepared?.defaultName
      ) { result in
        let outcome: Result<URL, any Error>? = {
          if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled {
            return nil
          }
          return result
        }()
        finish(outcome)
      }
      .onChange(of: exporting) { _, now in
        // The sheet was dismissed without the completion (a swipe down): the request is spent.
        if !now, prepared != nil { finish(nil) }
      }
  }

  /// Builds what the exporter is handed — the locked file away from the main thread — then shows
  /// the exporter. A file that cannot be locked is told as a failed export.
  private func prepare(_ answer: EncryptedExportForm.Answer) async {
    guard let export = request else { return }
    working = true
    let schema = environment.stack?.applied.onDisk ?? 0
    #if os(macOS)
      // The phone says it in its sheet; the Mac in the panel of an archive at work.
      let shown: (() -> Void)? =
        answer == .plain ? nil : EncryptedExportPrompt.showProgress(environment)
    #else
      let shown: (() -> Void)? = nil
    #endif
    do {
      let ready = try await export.prepared(
        for: answer, appVersion: AppEnvironment.appVersion, schemaVersion: schema)
      shown?()
      working = false
      form.reset()
      prepared = ready
      #if os(macOS)
        exporting = true
      #else
        asking = false
      #endif
    } catch {
      shown?()
      working = false
      form.reset()
      AppLog.error(
        "export.locked.failed", .archive, "the table could not be locked",
        [LogPair("error", .error(error))])
      request = nil
      #if os(macOS)
        onFinished(.failure(error))
      #else
        failure = error
        asking = false
      #endif
    }
  }

  private func finish(_ outcome: Result<URL, any Error>?) {
    guard request != nil || prepared != nil else { return }
    request = nil
    prepared = nil
    form.reset()
    onFinished(outcome)
  }
}

/// The phone's question in front of a table export: the warning about names and amounts, the box
/// «Зашифровать» (on) and, while it is on, the password twice. «Экспортировать» waits for a
/// password that is typed and repeated; the lock is made while the sheet says so.
private struct EncryptedExportSheet: View {
  @Binding var form: EncryptedExportForm
  let working: Bool
  let environment: AppEnvironment
  let cancel: () -> Void
  let export: () -> Void

  private func privacy(_ key: String) -> String {
    environment.language(key, table: "PrivacyExport")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(verbatim: environment.language("export.warning.body", table: "Settings"))
            .foregroundStyle(.secondary)
        }
        Section {
          Toggle(
            environment.language(EncryptedExportForm.boxKey, table: "Reports"),
            isOn: $form.encrypt
          )
          .accessibilityIdentifier("export.encrypt")
          Text(verbatim: environment.language("export.encrypt.note", table: "Reports"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
          if form.encrypt {
            SecureField(privacy("privacy.copy.password"), text: $form.password)
              .accessibilityIdentifier("export.encrypt.password")
            SecureField(privacy("privacy.copy.passwordAgain"), text: $form.confirmation)
              .accessibilityIdentifier("export.encrypt.passwordAgain")
            if let problem = form.problemShown() {
              Label {
                Text(verbatim: privacy(problem.messageKey))
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              .appFont(.callout)
              .foregroundStyle(.orange)
            }
          }
        }
        if working {
          Section {
            ProgressView()
              .frame(maxWidth: .infinity)
          }
        }
      }
      .navigationTitle(
        Text(verbatim: environment.language("export.warning.title", table: "Settings"))
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(environment.language("action.cancel"), action: cancel)
            .disabled(working)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(environment.language("action.export"), action: export)
            .disabled(form.answer == nil || working)
            .accessibilityIdentifier("export.encrypt.go")
        }
      }
    }
    .interactiveDismissDisabled(working)
  }
}
