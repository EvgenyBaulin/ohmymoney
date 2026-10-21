import SwiftUI
import UniformTypeIdentifiers

/// Files that carry the owner's data, ready to be handed to a file exporter: one CSV, or a folder
/// of them. The phone's counterpart of the Mac's save and folder panels.
struct PersonalDataExport: Equatable {
  struct File: Equatable {
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
}

/// The document the exporter writes: a CSV file or a folder of them.
struct PersonalDataDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.commaSeparatedText, .folder]
  static let writableContentTypes: [UTType] = [.commaSeparatedText, .folder]

  let export: PersonalDataExport

  init(_ export: PersonalDataExport) { self.export = export }

  init(configuration: ReadConfiguration) throws {
    // Nothing of the app opens these files; the type is only here to be written.
    throw CocoaError(.fileReadUnsupportedScheme)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
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

extension View {
  /// Says that the files carry personal data, then offers them to the file exporter. `request`
  /// is set by the button; it goes back to nil when the owner declined or the exporter is done.
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
  @State private var warned = false
  @State private var exporting = false

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        environment.language("export.warning.title", table: "Settings"),
        isPresented: Binding(
          get: { request != nil && !warned && !exporting },
          set: { if !$0, !warned, !exporting { request = nil } }),
        titleVisibility: .visible
      ) {
        Button(environment.language("action.export")) {
          warned = true
          exporting = true
        }
        Button(environment.language("action.cancel"), role: .cancel) { request = nil }
      } message: {
        Text(verbatim: environment.language("export.warning.body", table: "Settings"))
      }
      .fileExporter(
        isPresented: $exporting,
        document: request?.document,
        contentType: request?.contentType ?? .commaSeparatedText,
        defaultFilename: request?.defaultName
      ) { result in
        let outcome: Result<URL, any Error>? = {
          if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled {
            return nil
          }
          return result
        }()
        request = nil
        warned = false
        onFinished(outcome)
      }
      .onChange(of: exporting) { _, now in
        // The sheet was dismissed without the completion (a swipe down): the request is spent.
        if !now, request != nil, warned {
          request = nil
          warned = false
        }
      }
  }
}
