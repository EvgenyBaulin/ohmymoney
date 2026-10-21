import AppCore
import SwiftUI

/// The «Что если…» window: the changes the owner types on the left, what they do to the free
/// money month by month on the right. Everything is worked out by the core's `ScenarioEngine`
/// from a copy of today's planning snapshot; nothing is written to the database.
struct WhatIfWindow: View {
  static let minimumWidth: CGFloat = 720

  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }

  @State private var draft = WhatIfDraft()
  @State private var saved: [Scenario] = []
  @State private var name = ""
  @State private var openedId: UUID?

  private func text(_ key: String) -> String { environment.language(key, table: "WhatIf") }

  private var baseline: ScenarioBaseline? {
    compute.states.data.value.map { ScenarioBaseline(snapshot: $0.planning) }
  }

  var body: some View {
    HSplitView {
      form
        .sheetFrame(minWidth: 320, idealWidth: 360)
      result
        .sheetFrame(minWidth: 360)
    }
    .sheetFrame(minWidth: Self.minimumWidth, minHeight: 440)
    .journalsSection("whatif", in: .whatIf)
    .toolbar { ToolbarItem { savedMenu } }
    .onAppear(perform: reloadSaved)
  }

  // MARK: Saved scenarios

  private func reloadSaved() {
    saved = (try? environment.scenarios?.scenarios()) ?? []
  }

  /// Writes the form as a scenario (new, or over the one opened) in one step of ⌘Z.
  private func save() {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repository = environment.scenarios, !title.isEmpty else { return }
    let existing = saved.first { $0.id == openedId }
    var row =
      existing ?? Scenario(name: title, specJSON: draft.spec.json())
    row.name = title
    row.specJSON = draft.spec.json()
    if let change = try? repository.saving(row), deps.store.apply(change) {
      openedId = row.id
      reloadSaved()
    }
  }

  private func open(_ scenario: Scenario) {
    guard let spec = ScenarioSpec(json: scenario.specJSON) else { return }
    draft = WhatIfDraft(spec)
    name = scenario.name
    openedId = scenario.id
  }

  private func delete(_ scenario: Scenario) {
    if let change = try? environment.scenarios?.deleting(scenario.id), deps.store.apply(change) {
      if openedId == scenario.id { openedId = nil }
      reloadSaved()
    }
  }

  private var savedMenu: some View {
    Menu(text("whatif.saved")) {
      ForEach(saved) { scenario in
        Menu(scenario.name) {
          Button(text("whatif.open")) { open(scenario) }
          Button(text("whatif.delete"), role: .destructive) { delete(scenario) }
        }
      }
      if saved.isEmpty { Text(verbatim: text("whatif.noneSaved")) }
    }
  }

  // MARK: The form

  private var form: some View {
    Form {
      ForEach($draft.rows) { $row in
        Section {
          Picker(text("whatif.kind"), selection: $row.kind) {
            ForEach(WhatIfRow.kinds, id: \.self) { kind in
              Text(verbatim: text("whatif.kind.\(kind.rawValue)")).tag(kind)
            }
          }
          if row.asksForAmount {
            TextField(text("whatif.amount"), text: $row.amount)
              .monospacedDigit()
          }
          if row.asksForMonths {
            TextField(text("whatif.months"), text: $row.months).monospacedDigit()
          }
          if row.asksForRate {
            TextField(text("whatif.rate"), text: $row.rate).monospacedDigit()
          }
          if draft.rows.count > 1 {
            Button(text("whatif.removeChange"), role: .destructive) {
              draft.rows.removeAll { $0.id == row.id }
            }
          }
        }
      }
      Section {
        TextField(text("whatif.name"), text: $name)
        Button(text("whatif.save")) { save() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Section {
        Button(text("whatif.addChange")) { draft.rows.append(WhatIfRow()) }
        TextField(text("whatif.horizon"), text: $draft.horizon).monospacedDigit()
      }
      if draft.unreadRows > 0 {
        Text(verbatim: text("whatif.unread")).appFont(.footnote).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: The result

  @ViewBuilder
  private var result: some View {
    if let baseline {
      let spec = draft.spec
      let trajectory = ScenarioEngine.run(spec, from: baseline)
      VStack(alignment: .leading, spacing: 12) {
        Text(verbatim: verdict(trajectory)).appFont(.headline)
        Text(
          verbatim: environment.format(
            "whatif.lowest", table: "WhatIf",
            environment.money.rounded(trajectory.lowestFreeE4))
        ).appFont(.subheadline).foregroundStyle(.secondary)
        List(trajectory.points, id: \.month) { point in
          HStack {
            Text(verbatim: environment.format("whatif.month", table: "WhatIf", counts: point.month))
            Spacer()
            Text(verbatim: environment.money.rounded(point.freeE4)).monospacedDigit()
          }
        }
      }
      .padding(16)
    } else {
      Text(verbatim: text("whatif.waiting")).foregroundStyle(.secondary)
    }
  }

  /// The one sentence on top: when the money runs short, or that it does not.
  private func verdict(_ trajectory: ScenarioTrajectory) -> String {
    if let month = trajectory.firstShortMonth {
      return environment.format("whatif.short", table: "WhatIf", counts: month)
    }
    return text("whatif.enough")
  }
}
