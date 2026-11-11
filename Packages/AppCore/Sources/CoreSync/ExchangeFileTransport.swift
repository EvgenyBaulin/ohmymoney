import Foundation

/// A remote file, with no row contents or device display name in its metadata.
public struct ExchangeFileInfo: Sendable, Hashable {
  public var name: String
  public var modified: Date

  public init(name: String, modified: Date) {
    self.name = name
    self.modified = modified
  }
}

/// Storage of whole encrypted exchange files. Calls block and belong off the main thread.
/// Ordering, outbox retirement and conflicts belong to the exchange, never to this transport.
public protocol ExchangeFileTransport: Sendable {
  /// All committed files, including every page of a remote listing. No temporary files.
  func files() throws -> [ExchangeFileInfo]
  func readFile(named name: String) throws -> Data
  /// Commit whole bytes atomically. Without `replacing`, an existing file must either have
  /// identical bytes (a retry after a lost acknowledgement) or be refused. Snapshots alone
  /// may be replaced. A failed request must not be reported as a successful commit.
  func writeFile(named name: String, data: Data, replacing: Bool) throws
}

/// Transport errors carry no server response, account information, paths or financial data.
public enum ExchangeTransportError: Error, Sendable, Equatable {
  case unavailable
  case missing
  case malformed
  case fileChanged
  case mainThread
}
