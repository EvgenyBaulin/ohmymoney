import Foundation

/// One row of «Ещё»: a section the bar does not carry, a window of the Mac, or a tool.
enum MoreRow: Hashable, Identifiable, Sendable {
  case section(NavItem)
  case whatIf
  /// Only while the trip mode is on.
  case trip
  case reconcile
  case settings
  case tour
  case whatsNew
  case problemReport

  var id: String {
    switch self {
    case .section(let item): "section.\(item.rawValue)"
    case .whatIf: "whatIf"
    case .trip: "trip"
    case .reconcile: "reconcile"
    case .settings: "settings"
    case .tour: "tour"
    case .whatsNew: "whatsNew"
    case .problemReport: "problemReport"
    }
  }

  var symbol: String {
    switch self {
    case .section(let item): item.symbol
    case .whatIf: "slider.horizontal.3"
    case .trip: "airplane"
    case .reconcile: "checkmark.seal"
    case .settings: "gearshape"
    case .tour: "map"
    case .whatsNew: "sparkles"
    case .problemReport: "exclamationmark.bubble"
    }
  }
}

/// What «Ещё» lists, in two groups: the sections and what the bar cannot carry, then the
/// application's own (settings, guide, report of a problem).
struct MoreMenu: Equatable, Sendable {
  var sections: [MoreRow]
  var app: [MoreRow]

  static func make(more: [NavItem], tripIsOn: Bool) -> MoreMenu {
    var sections = more.map(MoreRow.section)
    sections.append(.whatIf)
    if tripIsOn { sections.append(.trip) }
    sections.append(.reconcile)
    return MoreMenu(sections: sections, app: [.settings, .tour, .whatsNew, .problemReport])
  }

  /// The rows whose title holds `query`, ignoring case and diacritics (ё = е as everywhere).
  func filtered(by query: String, title: (MoreRow) -> String) -> MoreMenu {
    let needle = Self.fold(query)
    guard !needle.isEmpty else { return self }
    func keep(_ row: MoreRow) -> Bool { Self.fold(title(row)).contains(needle) }
    return MoreMenu(sections: sections.filter(keep), app: app.filter(keep))
  }

  private static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
      .folding(options: [.caseInsensitive], locale: nil)
  }
}
