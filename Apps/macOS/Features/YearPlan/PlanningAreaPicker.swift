import SwiftUI

/// What Planning shows: the blocks of this month, or the plan of the year (`YearPlanPage`).
enum PlanningArea: String, CaseIterable, Identifiable {
  case month
  case year

  var id: String { rawValue }

  var titleKey: String { "area.\(rawValue)" }
}

/// «Месяц | Год» under the title of Planning. «Год» is a section of Planning, not a place of its
/// own in the sidebar; the choice lasts as long as the window and is never kept.
struct PlanningAreaPicker: View {
  @Dependency(\.environment) private var environment
  @Binding var area: PlanningArea

  var body: some View {
    Picker(YearText.t("area.label", environment), selection: $area) {
      ForEach(PlanningArea.allCases) { area in
        Text(verbatim: YearText.t(area.titleKey, environment)).tag(area)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("planning.area")
  }
}
