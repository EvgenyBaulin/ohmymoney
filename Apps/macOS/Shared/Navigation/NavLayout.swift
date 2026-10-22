import Foundation

/// The sections the bar of the phone and the iPad can carry, in the order an iPad shows them as
/// its window widens. The Mac has a sidebar and does not use the bar, but the list and the
/// layout are plain logic and live here so one test covers them on every platform.
enum NavItem: String, CaseIterable, Hashable, Sendable, Identifiable {
  case overview, operations, planning, accounts, calendar, capital, debts, analytics, goals,
    reports

  var id: String { rawValue }

  /// The key of the title; `titleTable` is the String Catalog it lives in (`nil` is Common).
  var titleKey: String {
    switch self {
    case .overview: "section.overview"
    case .operations: "section.operations"
    case .planning: "section.planning"
    case .accounts: "accounts.section.accounts"
    case .calendar: "section.calendar"
    case .capital: "section.capital"
    case .debts: "section.debts"
    case .analytics: "window.analytics"
    case .goals: "goals.title"
    case .reports: "window.reports"
    }
  }

  var titleTable: String? {
    switch self {
    case .accounts: "Accounts"
    case .goals: "Planning"
    default: nil
    }
  }

  /// Line symbols only: the bar draws outlines, and the active one is told by its pill.
  var symbol: String {
    switch self {
    case .overview: "house"
    case .operations: "list.bullet"
    case .planning: "calendar"
    case .accounts: "wallet.bifold"
    case .calendar: "calendar.circle"
    case .capital: "building.columns"
    case .debts: "creditcard"
    case .analytics: "chart.xyaxis.line"
    case .goals: "target"
    case .reports: "tablecells"
    }
  }

  /// The four a phone shows until the owner chooses others.
  static let defaultPhoneTabs: [NavItem] = [.overview, .operations, .planning, .accounts]
}

/// Which sections the bar shows and which wait in «Ещё», for a window of a given width.
struct NavLayout: Equatable, Sendable {
  enum Placement: Equatable, Sendable {
    /// Full width, at the bottom: a phone, or an iPad window as narrow as one.
    case bottom
    /// At the top, no wider than half the window: an iPad.
    case top
  }

  var placement: Placement
  var visible: [NavItem]
  var more: [NavItem]

  /// A phone bar always has this many sections besides «Ещё».
  static let phoneSlots = 4
  /// Width of one section of the iPad bar, and what is left of it for «Ещё» and the margins.
  static let slotWidth: Double = 52
  static let reservedWidth: Double = 146
  /// The widest share of the window the iPad bar may take.
  static let widthShare: Double = 0.5
  /// An iPad window narrower than this (Split View, Slide Over) wears the phone bar.
  static let padMinimumWidth: Double = 744

  /// How many sections fit on the iPad bar at `width`, «Ещё» not counted.
  static func padSlots(width: Double) -> Int {
    let slots = ((widthShare * width - reservedWidth) / slotWidth).rounded(.down)
    return max(0, min(NavItem.allCases.count, Int(slots)))
  }

  /// The width the iPad bar takes with `slots` sections.
  static func padBarWidth(slots: Int) -> Double { Double(slots) * slotWidth + reservedWidth }

  /// - Parameters:
  ///   - width: the width of the window, in points.
  ///   - isPad: the device is an iPad.
  ///   - phoneTabs: the four the owner chose for the phone bar; anything else is the default.
  static func make(
    width: Double, isPad: Bool, phoneTabs: [NavItem] = NavItem.defaultPhoneTabs
  ) -> NavLayout {
    if isPad && width >= padMinimumWidth {
      let slots = padSlots(width: width)
      let all = NavItem.allCases
      return NavLayout(
        placement: .top, visible: Array(all.prefix(slots)), more: Array(all.dropFirst(slots)))
    }
    let chosen = PhoneTabsPreference.validated(phoneTabs) ?? NavItem.defaultPhoneTabs
    return NavLayout(
      placement: .bottom, visible: chosen,
      more: NavItem.allCases.filter { !chosen.contains($0) })
  }

  /// «Ещё» is always on the bar, so the whole count is the sections plus one.
  var barCount: Int { visible.count + 1 }
}

/// The four sections of the phone bar, as the owner chose them in «Ещё → Изменить». Kept in the
/// settings as `phone.tabs`, a comma-separated list of raw values.
enum PhoneTabsPreference {
  static let key = "phone.tabs"

  /// `items` if it is four different sections, else `nil`.
  static func validated(_ items: [NavItem]) -> [NavItem]? {
    items.count == NavLayout.phoneSlots && Set(items).count == items.count ? items : nil
  }

  static func encode(_ items: [NavItem]) -> String { items.map(\.rawValue).joined(separator: ",") }

  /// What a stored string says; a damaged or short one gives the default.
  static func decode(_ text: String?) -> [NavItem] {
    guard let text else { return NavItem.defaultPhoneTabs }
    let items = text.split(separator: ",").compactMap { NavItem(rawValue: String($0)) }
    return validated(items) ?? NavItem.defaultPhoneTabs
  }

  static func load(_ defaults: UserDefaults = .standard) -> [NavItem] {
    decode(defaults.string(forKey: key))
  }

  /// Returns whether it was kept: only four different sections are.
  @discardableResult
  static func save(_ items: [NavItem], to defaults: UserDefaults = .standard) -> Bool {
    guard validated(items) != nil else { return false }
    defaults.set(encode(items), forKey: key)
    return true
  }
}
