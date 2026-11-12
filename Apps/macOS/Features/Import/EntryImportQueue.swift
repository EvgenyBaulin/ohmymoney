import Foundation
import Observation
import UniformTypeIdentifiers

struct EntryImportFile: Equatable, Sendable {
  let data: Data
  let filename: String
}

enum EntryImportFileKind: Equatable {
  case statement, spreadsheet, document

  static func of(_ filename: String) -> Self? {
    let ext = (filename as NSString).pathExtension.lowercased()
    if ["csv", "txt", "tsv"].contains(ext) { return .statement }
    if ext == "xlsx" { return .spreadsheet }
    if ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
      return .document
    }
    return nil
  }
}

struct EntryImportSource: Identifiable {
  let id = UUID()
  var url: URL? = nil
  var file: EntryImportFile? = nil
}

/// The same queue serves the paperclip, drops and paste. Closing one sheet offers the next
/// file. A lock only covers the current sheet; it never consumes a queued file.
@MainActor
@Observable
final class EntryImportQueue {
  var active: EntryImportSource?
  private var pending: [EntryImportSource] = []

  @discardableResult
  func append(urls: [URL]) -> Bool {
    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
    append(urls.map { EntryImportSource(url: $0) })
    return true
  }

  func append(_ sources: [EntryImportSource]) {
    pending += sources
    presentNext()
  }

  func didDismiss(isCovered: Bool) {
    guard !isCovered, active == nil else { return }
    presentNext()
  }

  private func presentNext() {
    guard active == nil, !pending.isEmpty else { return }
    active = pending.removeFirst()
  }
}

/// File URLs take precedence over a provider's thumbnail or text representation. Plain text
/// is deliberately left to the text field and its existing SMS parser.
@MainActor
enum EntryImportProvider {
  static let types: [UTType] = [.fileURL, .pdf, .image, .spreadsheet, .commaSeparatedText]

  enum Failure: Error { case unreadable }

  static func read(_ provider: NSItemProvider) async throws -> EntryImportSource {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      let data = try await bytes(provider, identifier: UTType.fileURL.identifier)
      guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
        throw Failure.unreadable
      }
      return EntryImportSource(url: url)
    }
    for base in types.dropFirst() {
      guard
        let identifier = provider.registeredTypeIdentifiers.first(where: {
          UTType($0)?.conforms(to: base) == true
        })
      else { continue }
      let data = try await bytes(provider, identifier: identifier)
      let ext = UTType(identifier)?.preferredFilenameExtension ?? "bin"
      let name = provider.suggestedName ?? "import.\(ext)"
      let filename = (name as NSString).pathExtension.isEmpty ? "\(name).\(ext)" : name
      return EntryImportSource(file: EntryImportFile(data: data, filename: filename))
    }
    throw Failure.unreadable
  }

  private static func bytes(_ provider: NSItemProvider, identifier: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? Failure.unreadable)
        }
      }
    }
  }
}
