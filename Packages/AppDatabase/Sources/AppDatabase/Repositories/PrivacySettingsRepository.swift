import CoreKit
import Foundation
import GRDB

/// The settings of the privacy features (`privacy.*` keys of the `settings` table). A key that was
/// never written reads as its default.
public struct PrivacySettingsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func settings() throws -> PrivacySettings {
    try writer.read { db in
      PrivacySettings(
        storedValues: try SettingsRepository.values(of: PrivacySettings.storageKeys, db: db))
    }
  }

  public func save(_ settings: PrivacySettings) throws {
    try writer.write { db in
      for (key, value) in settings.storedValues {
        try SettingsRepository.set(key, to: value, in: db)
      }
    }
  }
}
