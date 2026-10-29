import Foundation

/// The keys of the privacy settings and their defaults. The values live in the settings of the
/// device (they say how this screen behaves, not what the owner's money is), so none of them
/// travels in the archive.
public enum PrivacySettings {
  /// Hide the amounts by themselves while the screen is recorded, mirrored or shared.
  public static let autoHideOnCaptureKey = "privacy.autoHideOnCapture"
  /// How many days the privacy journal keeps its lines.
  public static let journalDaysKey = "privacy.journalDays"

  public static let autoHideOnCaptureDefault = true
  public static let journalDaysDefault = 365
  public static let journalDaysRange = 1...3650
}

/// What decides whether the amounts are hidden right now. Pure: the app reads the system and
/// the settings and hands the facts in.
public enum RecordingPolicy {
  /// What is watching the screen.
  public struct Capture: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The screen is being recorded or screenshotted by the system recorder.
    public static let recording = Capture(rawValue: 1 << 0)
    /// The screen is mirrored to another display (AirPlay, cable).
    public static let mirroring = Capture(rawValue: 1 << 1)
    /// The screen or the window is shared in a call.
    public static let sharing = Capture(rawValue: 1 << 2)
  }

  public struct Signals: Hashable, Sendable {
    public var capture: Capture
    /// `privacy.autoHideOnCapture`.
    public var autoHideOnCapture: Bool
    /// The owner pressed «Скрыть суммы».
    public var manuallyHidden: Bool

    public init(
      capture: Capture = [], autoHideOnCapture: Bool = PrivacySettings.autoHideOnCaptureDefault,
      manuallyHidden: Bool = false
    ) {
      self.capture = capture
      self.autoHideOnCapture = autoHideOnCapture
      self.manuallyHidden = manuallyHidden
    }
  }

  /// Why the amounts are hidden; the raw value is the token the journal and the interface use.
  public enum Reason: String, Hashable, Sendable, CaseIterable {
    case manual = "privacy.hide.manual"
    case capture = "privacy.hide.capture"
  }

  public struct Decision: Hashable, Sendable {
    public var hide: Bool
    /// `nil` when nothing hides the amounts.
    public var reason: Reason?
  }

  /// The owner's own choice wins and is named first; a capture hides only when the setting is on.
  public static func decide(_ signals: Signals) -> Decision {
    if signals.manuallyHidden { return Decision(hide: true, reason: .manual) }
    if signals.autoHideOnCapture, !signals.capture.isEmpty {
      return Decision(hide: true, reason: .capture)
    }
    return Decision(hide: false, reason: nil)
  }
}
