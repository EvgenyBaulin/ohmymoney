import AppCore
import Foundation

// Interim registry of the drives of this branch. The shared list of drives belongs to the
// settings work of the other branch; after the merge these three entries move into it.

enum CloudDriveKindB: String, CaseIterable, Sendable {
  case googleDrive
  case mailRuCloud
  case supabase

  var titleKey: String {
    switch self {
    case .googleDrive: "cloud.google.title"
    case .mailRuCloud: "cloud.mailru.title"
    case .supabase: "cloud.supabase.title"
    }
  }

  /// Drives the owner reaches with a key the app ships need that key registered first; the other
  /// two take what the owner types.
  var needsAppKey: Bool { self == .googleDrive }

  var isConnectable: Bool {
    switch self {
    case .googleDrive: GoogleDriveConfig.isConfigured
    case .mailRuCloud, .supabase: true
    }
  }

  /// Why "Connect" is unavailable, or `nil` when it is available.
  var unavailableReasonKey: String? {
    isConnectable ? nil : "cloud.keyMissing"
  }

  /// Shown until the files of the exchange are encrypted before they leave the device.
  var openFilesWarningKey: String { "cloud.openFilesWarning" }
}
