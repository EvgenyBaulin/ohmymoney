import CoreKit
import Foundation

/// What the owner asked of «Экспорт копии»: which part of the history, whether the names are
/// replaced, whether the hidden accounts and the attached files go, and the password the copy is
/// locked with. The copy is made from a copy of the data; the originals do not change.
public struct ExportCopyRequest: Sendable, Equatable {
  public enum Scope: Sendable, Equatable {
    /// The whole history.
    case whole
    /// The operations and transfers of these days only.
    case period(DayRange)
  }

  /// How the copy is packed. Both are locked with the password.
  public enum Format: Sendable, Equatable {
    /// The archive of a transfer: the database, the CSV files and the settings.
    case archive
    /// The CSV files alone, in the same container: it cannot be imported back.
    case csvOnly
  }

  public var scope: Scope
  /// Names of people, places, accounts, events and the free texts are replaced by neutral ones.
  public var anonymize: Bool
  /// The hidden accounts, their operations and their transfers are in the copy.
  public var includeHidden: Bool
  /// The attached files are in the copy (those of the operations that stay).
  public var includeAttachments: Bool
  /// Never empty for a copy that leaves the Mac: everything that goes out is locked.
  public var password: String
  public var format: Format

  public init(
    scope: Scope = .whole, anonymize: Bool = false, includeHidden: Bool = true,
    includeAttachments: Bool = false, password: String, format: Format = .archive
  ) {
    self.scope = scope
    self.anonymize = anonymize
    self.includeHidden = includeHidden
    self.includeAttachments = includeAttachments
    self.password = password
    self.format = format
  }
}
