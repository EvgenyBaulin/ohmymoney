import Foundation

/// Application ids of the cloud drives. They are public identifiers (the apps use PKCE and keep
/// no secret), left empty until the owner registers each application: a drive without an id is
/// listed but cannot be connected. Steps for each drive are in Personal/Checks.md.
enum CloudDriveKeys {
  static let google = ""
  static let yandex = ""
  static let dropbox = ""
  static let oneDrive = ""
}
