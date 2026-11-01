import SwiftUI

/// «Компактно» and «Подробно» of a list: compact draws its rows a step smaller and closer, so
/// more of them fit; detailed is the list as it always was. Each list remembers its own choice on
/// this Mac (`lists.compact.<list>`), never in the database or an archive.
enum DensityList: String, CaseIterable, Sendable {
  case operations
  case debts
  case purchases

  var key: String { "lists.compact.\(rawValue)" }
}

enum ListDensity {
  /// The size of the text of a compact list: one step below the size chosen in Settings →
  /// Appearance, never below the smallest.
  static func fontSize(_ chosen: AppFontSize, compact: Bool) -> AppFontSize {
    guard compact else { return chosen }
    switch chosen {
    case .small, .regular: return .small
    case .large: return .regular
    case .xlarge: return .large
    }
  }

  /// The least height of a row: what a compact list packs its rows to; `nil` — as the list lays
  /// them out itself.
  static func minimumRowHeight(compact: Bool) -> CGFloat? { compact ? 18 : nil }
}

/// The list drawn as its own choice says.
private struct ListDensityModifier: ViewModifier {
  let list: DensityList
  @AppStorage private var compact: Bool
  @Environment(\.appFontSize) private var chosen

  init(list: DensityList) {
    self.list = list
    _compact = AppStorage(wrappedValue: false, list.key)
  }

  func body(content: Content) -> some View {
    if let height = ListDensity.minimumRowHeight(compact: compact) {
      content
        .environment(\.appFontSize, ListDensity.fontSize(chosen, compact: true))
        .environment(\.defaultMinListRowHeight, height)
        .controlSize(.small)
    } else {
      content
    }
  }
}

/// The one button that switches a list between compact and detailed.
struct ListDensityToggle: View {
  let list: DensityList
  let compactTitle: String
  let detailedTitle: String
  @AppStorage private var compact: Bool

  init(list: DensityList, compactTitle: String, detailedTitle: String) {
    self.list = list
    self.compactTitle = compactTitle
    self.detailedTitle = detailedTitle
    _compact = AppStorage(wrappedValue: false, list.key)
  }

  var body: some View {
    Button {
      compact.toggle()
    } label: {
      Label {
        Text(verbatim: compact ? detailedTitle : compactTitle)
      } icon: {
        Image(systemName: compact ? "list.bullet" : "list.dash")
      }
    }
    .help(compact ? detailedTitle : compactTitle)
    .accessibilityIdentifier("density.\(list.rawValue)")
  }
}

extension View {
  func listDensity(_ list: DensityList) -> some View {
    modifier(ListDensityModifier(list: list))
  }
}
