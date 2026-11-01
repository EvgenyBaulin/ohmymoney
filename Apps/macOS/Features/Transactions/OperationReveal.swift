import Foundation

/// An operation asked for from outside «Операции» — a result of Spotlight opened: the screen
/// shows its day, selects it and opens it in the editor. Kept until the screen takes it, so a
/// request made while another section is shown is found when «Операции» appears.
@MainActor
enum OperationReveal {
  private static var pending: UUID?

  static func ask(_ id: UUID) {
    pending = id
    NotificationCenter.default.post(name: .revealOperation, object: nil)
    NotificationCenter.default.post(
      name: .openSidebarItem, object: SidebarItem.section(.operations))
  }

  static func take() -> UUID? {
    defer { pending = nil }
    return pending
  }
}

extension Notification.Name {
  static let revealOperation = Notification.Name("io.github.EvgenyBaulin.ohmymoney.revealOperation")
}
