import Foundation

/// A column of the table of «Операции». The raw value is what `OperationColumnLayout` keeps in
/// `UserDefaults`: it is never renamed.
enum OperationColumn: String, CaseIterable, Identifiable, Hashable, Sendable {
  case time
  case description
  case amount
  case category
  case account
  case place
  case forWhom
  case quality
  case cashback
  case note
  case event

  var id: String { rawValue }

  /// The key of its title in the «Transactions» table of strings.
  var titleKey: String {
    switch self {
    case .account: "transactions.column.paymentMethod"
    default: "transactions.column.\(rawValue)"
    }
  }

  /// The description and the amount name the row: they are always shown.
  var canBeHidden: Bool { self != .description && self != .amount }

  /// Shown until the owner says otherwise.
  var shownByDefault: Bool { self != .event }

  /// The narrowest a column may be: what its fixed text needs (`TransactionColumnWidths`).
  var minimumWidth: Int {
    switch self {
    case .time: 64
    case .amount: 104
    case .description: 120
    case .category: 80
    default: 60
    }
  }

  /// The width a column starts with.
  var standardWidth: Int {
    switch self {
    case .time: 64
    case .description: 180
    case .amount: 104
    case .category: 140
    case .account: 110
    case .place: 90
    case .forWhom: 80
    case .quality: 80
    case .cashback: 80
    case .note: 140
    case .event: 90
    }
  }

  /// The widest the owner can make it in «Настроить столбцы…».
  var maximumWidth: Int {
    switch self {
    case .time: 96
    case .amount, .quality, .cashback: 200
    case .description, .note: 600
    default: 400
    }
  }

  /// Amounts line up on the right.
  var isNumeric: Bool { self == .amount || self == .cashback }
}

/// Which columns of «Операции» are shown, in which order and how wide: a setting of this Mac,
/// kept in `UserDefaults` under `storageKey` as one line of text — never in the database or an
/// archive. «Настроить столбцы…» edits it; «Сбросить к настройкам по умолчанию» brings back
/// `standard`.
///
/// The text lists every column in its order, separated by commas; a hidden one starts with «-»
/// and a width the owner chose follows a colon: `time,description:220,amount,-event:90`. Reading
/// it, an unknown name is dropped, a repeated one keeps its first place, a column not named comes
/// at its standard place in the order and with its standard visibility, and a width is kept inside
/// the column's bounds. The description and the amount are never hidden.
struct OperationColumnLayout: Hashable, Sendable {
  static let storageKey = "operations.columns"

  private(set) var order: [OperationColumn]
  private(set) var hidden: Set<OperationColumn>
  private(set) var widths: [OperationColumn: Int]

  static let standard = OperationColumnLayout(
    order: OperationColumn.allCases,
    hidden: Set(OperationColumn.allCases.filter { !$0.shownByDefault }), widths: [:])

  private init(
    order: [OperationColumn], hidden: Set<OperationColumn>, widths: [OperationColumn: Int]
  ) {
    self.order = order
    self.hidden = hidden
    self.widths = widths
  }

  /// The layout kept as text; nothing, or a text naming nothing known, is `standard`.
  init(storage: String?) {
    var order: [OperationColumn] = []
    var hidden: Set<OperationColumn> = []
    var widths: [OperationColumn: Int] = [:]
    var named: Set<OperationColumn> = []
    for item in (storage ?? "").split(separator: ",") {
      var word = item.trimmingCharacters(in: .whitespaces)
      let hides = word.hasPrefix("-")
      if hides { word.removeFirst() }
      let pieces = word.split(separator: ":", maxSplits: 1).map(String.init)
      guard let name = pieces.first, let column = OperationColumn(rawValue: name),
        named.insert(column).inserted
      else { continue }
      order.append(column)
      if hides, column.canBeHidden { hidden.insert(column) }
      if pieces.count == 2, let width = Int(pieces[1]) {
        widths[column] = Self.clamped(width, column)
      }
    }
    // A column the text does not name — one added after the text was written — takes its
    // standard place: after the columns that stand before it in the standard order.
    for column in OperationColumn.allCases where !named.contains(column) {
      let before = OperationColumn.allCases.prefix { $0 != column }
      let index = order.lastIndex { before.contains($0) }.map { $0 + 1 } ?? 0
      order.insert(column, at: index)
      if !column.shownByDefault { hidden.insert(column) }
    }
    self.init(order: order, hidden: hidden, widths: widths)
  }

  /// The text kept in `UserDefaults`.
  var storage: String {
    order.map { column in
      let name = (hidden.contains(column) ? "-" : "") + column.rawValue
      return widths[column].map { "\(name):\($0)" } ?? name
    }
    .joined(separator: ",")
  }

  /// The columns the table shows, in their order.
  var visible: [OperationColumn] { order.filter { !hidden.contains($0) } }

  func isShown(_ column: OperationColumn) -> Bool { !hidden.contains(column) }

  /// The width the column is laid out with: the owner's, or its standard one.
  func width(of column: OperationColumn) -> Int {
    widths[column] ?? column.standardWidth
  }

  /// Shows or hides a column; the description and the amount stay.
  mutating func setShown(_ shown: Bool, _ column: OperationColumn) {
    if shown {
      hidden.remove(column)
    } else if column.canBeHidden {
      hidden.insert(column)
    }
  }

  /// A width for the column, kept inside its bounds.
  mutating func setWidth(_ width: Int, of column: OperationColumn) {
    widths[column] = Self.clamped(width, column)
  }

  /// Moves a column one place up (`offset` −1) or down (+1); at either end nothing moves.
  mutating func move(_ column: OperationColumn, by offset: Int) {
    guard let index = order.firstIndex(of: column) else { return }
    let target = index + offset
    guard order.indices.contains(target) else { return }
    order.swapAt(index, target)
  }

  /// A drag in the list of «Настроить столбцы…».
  mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    let moving = source.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
    guard !moving.isEmpty else { return }
    let before = order.prefix(min(max(destination, 0), order.count)).filter {
      !moving.contains($0)
    }.count
    var rest = order.filter { !moving.contains($0) }
    rest.insert(contentsOf: moving, at: before)
    order = rest
  }

  private static func clamped(_ width: Int, _ column: OperationColumn) -> Int {
    min(max(width, column.minimumWidth), column.maximumWidth)
  }
}
