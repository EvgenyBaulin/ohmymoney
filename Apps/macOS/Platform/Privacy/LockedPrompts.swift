import SwiftUI

/// A question the app raises by itself — the offer of a report after a crash, the reminders and
/// the overdue payments, the cards of the guide, the starter set and the setup of the accounts,
/// the questions after a restore or an import — never stands over the cover of the locked app.
/// A sheet or an alert is modal: over the cover of its window it takes the clicks and the keys
/// the cover needs, and the app could not be entered (1.8.0, after a force quit, at every launch).
///
/// Each such presentation goes through these. While the app is locked it is not shown, and one
/// on screen when the lock comes goes away; what SwiftUI writes back as it takes it down is not
/// kept, so the question is neither spent nor answered and comes back once the app is unlocked.
extension PrivacyLock {
  /// Whether a question the app raises by itself may be on screen now.
  func lets(_ question: Bool) -> Bool { question && !isCovered }

  /// `binding`, false while the app is locked; writes made while locked are dropped.
  func presenting(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(
      get: { self.lets(binding.wrappedValue) },
      set: { if !self.isCovered { binding.wrappedValue = $0 } })
  }

  /// `binding`, nil while the app is locked; writes made while locked are dropped.
  func presenting<Item>(_ binding: Binding<Item?>) -> Binding<Item?> {
    Binding(
      get: { self.isCovered ? nil : binding.wrappedValue },
      set: { if !self.isCovered { binding.wrappedValue = $0 } })
  }
}
