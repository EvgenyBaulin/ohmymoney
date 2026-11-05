import AppCore
import SwiftUI

/// The mode of a beginner on this Mac: the switch (a habit of this Mac, never in the database or
/// the archive) and what it quiets now. A new book gets it on — the one the first month started
/// on —, a book in use gets it off; the owner switches it in the settings.
@MainActor
enum BeginnerModeOnMac {
  static let key = "habits.beginner"

  static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
    return FirstMonthStore.read(defaults) != nil
  }

  static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
  }

  /// What the mode reads from the data.
  static func facts(
    _ snapshot: DataSnapshot, hasLoans: Bool? = GuideStore.shared.progress.profile?.hasLoans
  )
    -> BeginnerFacts
  {
    let dataset = snapshot.ledger.dataset
    let typed = HabitEntryDays.typedDays(dataset.entries, calendar: snapshot.ledger.calendar)
    return BeginnerFacts(
      entryDays: HabitNotesOnMac.entryDays(snapshot).count, firstEntry: typed.min(),
      counts: dataset.planning.reconciliations.filter { $0.kind != .opening }.count,
      debts: dataset.debts.count, hasLoans: hasLoans, today: snapshot.today)
  }

  /// The quiet sections and what each waits for; nothing when the mode is off.
  static func quiet(
    _ snapshot: DataSnapshot?, defaults: UserDefaults = .standard
  )
    -> [BeginnerSection: BeginnerUnlock]
  {
    guard let snapshot else { return [:] }
    return BeginnerMode.quiet(enabled: enabled(defaults), facts: facts(snapshot))
  }

  /// The section of the beginner a section of the main window is, if any.
  static func section(of item: MainWindow.Section) -> BeginnerSection? {
    switch item {
    case .capital: .capital
    case .debts: .debts
    default: nil
    }
  }
}

extension BeginnerModeOnMac {
  /// The same for the rows of «Ещё» on an iPhone and an iPad, which list every section as a
  /// `NavItem`: the rules and the threshold are the ones the Mac sidebar uses.
  static func section(of item: NavItem) -> BeginnerSection? {
    switch item {
    case .capital: .capital
    case .debts: .debts
    case .analytics: .analytics
    case .reports: .reports
    default: nil
    }
  }
}

/// A row of the sidebar the mode of a beginner quiets: dimmed, with «Откроется, когда…» under its
/// name. It still opens — quiet, not locked.
struct BeginnerQuiet: ViewModifier {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let section: BeginnerSection?

  func body(content: Content) -> some View {
    if let section, let unlock = BeginnerModeOnMac.quiet(compute.snapshot)[section] {
      VStack(alignment: .leading, spacing: 1) {
        content.opacity(0.55)
        Text(verbatim: HabitText.unlock(unlock, environment))
          .appFont(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 34)
      }
      .accessibilityElement(children: .combine)
      .accessibilityHint(Text(verbatim: HabitText.t("beginner.caption", environment)))
    } else {
      content
    }
  }
}

extension View {
  func beginnerQuiet(_ section: BeginnerSection?) -> some View {
    modifier(BeginnerQuiet(section: section))
  }
}
