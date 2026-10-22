import AppCore
import Foundation

/// What a line of the palette does. The entries of the core are names and ids; this is where
/// each one is given a deed, so a line that does nothing cannot be added without a test saying so.
enum PaletteAction: Hashable, Sendable {
  case newOperation
  case newDebt
  case newGoal
  case newTransfer(from: UUID?)
  case reconcile
  case askQuestion
  case recompute
  case export
  case checkForUpdates
  case openSettings
  case openSection(MainWindow.Section)
  case openAnalytics
  case openReports
  case openAccount(UUID)
  case openDebts
  case openPlanning
  case operationsOfCategory(UUID)
  case operationsOfPerson(UUID)

  /// The deed of an entry; `nil` for an entry this build does not know.
  static func action(for entry: PaletteEntry) -> PaletteAction? {
    switch entry.id {
    case "command.newOperation": return .newOperation
    case "command.newDebt": return .newDebt
    case "command.newGoal": return .newGoal
    case "command.newTransfer": return .newTransfer(from: nil)
    case "command.reconcile": return .reconcile
    case "command.askQuestion": return .askQuestion
    case "command.recompute": return .recompute
    case "command.export": return .export
    case "command.checkForUpdates": return .checkForUpdates
    case "command.openSettings": return .openSettings
    case "screen.overview": return .openSection(.overview)
    case "screen.operations": return .openSection(.operations)
    case "screen.calendar": return .openSection(.calendar)
    case "screen.capital": return .openSection(.capital)
    case "screen.planning": return .openSection(.planning)
    case "screen.debts": return .openSection(.debts)
    case "screen.analytics": return .openAnalytics
    case "screen.reports": return .openReports
    default: break
    }
    guard let subject = entry.subjectId else { return nil }
    let verb = entry.id.split(separator: ".").dropFirst().first.map(String.init)
    switch (entry.kind, verb) {
    case (.account, "open"): return .openAccount(subject)
    case (.account, "reconcile"): return .reconcile
    case (.account, "transfer"): return .newTransfer(from: subject)
    case (.debt, "open"): return .openDebts
    case (.goal, "open"): return .openPlanning
    case (.category, "open"): return .operationsOfCategory(subject)
    case (.person, "open"): return .operationsOfPerson(subject)
    default: return nil
    }
  }

  /// Whether this platform can do it: the export and the update check are the Mac's.
  var isAvailableHere: Bool {
    switch self {
    case .export, .checkForUpdates:
      #if os(macOS)
        return true
      #else
        return false
      #endif
    default: return true
    }
  }
}

extension PaletteSource {
  /// What ⌘K can open in a snapshot: the live accounts, the open debts, the goals not
  /// archived, the categories and the people not in the archive.
  init(dataset: Dataset) {
    func named<T>(
      _ items: [T], _ id: KeyPath<T, UUID>, _ name: KeyPath<T, String>
    )
      -> [PaletteNamed]
    {
      items.map { PaletteNamed(id: $0[keyPath: id], name: $0[keyPath: name]) }
    }
    self.init(
      accounts: named(dataset.paymentMethods.filter { !$0.archived }, \.id, \.name),
      debts: named(dataset.debts.filter { !$0.closed && $0.deletedAt == nil }, \.id, \.name),
      goals: named(dataset.goals.filter { !$0.archived }, \.id, \.name),
      categories: named(dataset.categories.filter { !$0.archived }, \.id, \.name),
      people: named(dataset.people.filter { !$0.archived }, \.id, \.name))
  }

  /// The entries this platform can run.
  static func entries(for dataset: Dataset) -> [PaletteEntry] {
    PaletteCatalog.entries(for: PaletteSource(dataset: dataset)).filter {
      PaletteAction.action(for: $0)?.isAvailableHere ?? false
    }
  }
}
