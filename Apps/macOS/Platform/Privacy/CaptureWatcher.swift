import AppCore
import Foundation

#if canImport(AppKit)
  import AppKit
  import CoreGraphics
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// Tells the app what is watching the screen, from the system's own signs and nothing else.
///
/// * iPhone and iPad: `UIScreen.isCaptured` is true while the screen is recorded, mirrored or
///   sent over AirPlay, and `capturedDidChangeNotification` says when it changes.
/// * Mac: the system has no public sign of a screen recording or of a shared window (a window's
///   `sharingType` no longer does anything). What can be told is a display mirrored onto
///   another one, which is read from the display list. For a recording or a call the owner
///   uses «Скрыть суммы» (⌃⌘H).
@MainActor
final class CaptureWatcher {
  private var observers: [NSObjectProtocol] = []
  private let onChange: (RecordingPolicy.Capture) -> Void

  init(onChange: @escaping (RecordingPolicy.Capture) -> Void) {
    self.onChange = onChange
  }

  /// What is watching now.
  static func current() -> RecordingPolicy.Capture {
    var capture: RecordingPolicy.Capture = []
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
      let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
      if screens.contains(where: \.isCaptured) { capture.insert(.recording) }
    #elseif canImport(AppKit)
      var ids = [CGDirectDisplayID](repeating: 0, count: 16)
      var count: UInt32 = 0
      if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
        if ids.prefix(Int(count)).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
          capture.insert(.mirroring)
        }
      }
    #endif
    return capture
  }

  /// Starts to listen. Once.
  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
      observers.append(
        center.addObserver(
          forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        })
    #elseif canImport(AppKit)
      observers.append(
        center.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        })
    #endif
    report()
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }

  private func report() {
    onChange(Self.current())
  }
}
