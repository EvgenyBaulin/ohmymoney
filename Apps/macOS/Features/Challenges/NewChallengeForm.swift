import AppCore
import SwiftUI

/// A new challenge: a ready-made one fills the fields, and every field can be changed, so a
/// challenge of the owner's own is the same form with nothing filled in. A word list and a
/// category say what the challenge is about; with neither, every expense of mine counts.
struct NewChallengeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  let onSaved: () -> Void

  @State private var title = ""
  @State private var kind: ChallengeKind = .avoid
  @State private var days = 7
  @State private var start = Date()
  @State private var words = ""
  @State private var categoryId: UUID?
  @State private var limit: AmountE4 = .zero
  @State private var baseline: AmountE4 = .zero

  private func t(_ key: String) -> String { ChallengeText.t(key, environment) }

  private var categories: [CoreKit.Category] {
    (compute.snapshot?.ledger.dataset.categories ?? [])
      .filter { $0.kind == .expense && $0.parentId == nil && !$0.archived }
      .sorted { $0.sort < $1.sort }
  }

  private var startDay: DateOnly { environment.calendar.day(of: start) }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespaces).isEmpty
      && (kind != .cap || !limit.isZero)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("challenges.new")).appFont(.headline)
      Form {
        Section {
          ForEach(ChallengePreset.allCases, id: \.self) { preset in
            Button(presetTitle(preset)) { fill(preset) }
              .accessibilityIdentifier("challenge.preset.\(preset.rawValue)")
          }
          Text(verbatim: t("challenges.preset.hint")).appFont(.caption).secondaryInk()
        } header: {
          Text(verbatim: t("challenges.new.presets")).settingsHeaderStyle()
        }
        Section {
          TextField(text: $title) { Text(verbatim: t("challenges.form.name")) }
          Picker(t("challenges.form.kind"), selection: $kind) {
            ForEach(ChallengeKind.allCases, id: \.self) { kind in
              Text(verbatim: t("challenges.kind.\(kind.rawValue)")).tag(kind)
            }
          }
          Stepper(value: $days, in: 1...366) {
            Text(
              verbatim: environment.format(
                "challenges.form.days", table: ChallengeText.table, days))
          }
          DatePicker(t("challenges.form.start"), selection: $start, displayedComponents: .date)
          if kind != .noNewSubscriptions {
            TextField(text: $words) { Text(verbatim: t("challenges.form.words")) }
            Picker(t("challenges.form.category"), selection: $categoryId) {
              Text(verbatim: t("challenges.form.category.none")).tag(UUID?.none)
              ForEach(categories) { category in
                Text(verbatim: category.name).tag(UUID?.some(category.id))
              }
            }
            if words.trimmingCharacters(in: .whitespaces).isEmpty && categoryId == nil {
              Text(verbatim: t("challenges.form.everything")).appFont(.caption).secondaryInk()
            }
          }
          if kind == .cap {
            LabeledContent(t("challenges.form.limit")) {
              AmountField(amount: $limit, locale: environment.language.locale)
            }
          }
          if kind != .noNewSubscriptions {
            LabeledContent(t("challenges.form.baseline")) {
              AmountField(amount: $baseline, locale: environment.language.locale)
            }
            Text(verbatim: t("challenges.form.baselineHint")).appFont(.caption).secondaryInk()
          }
        }
      }
      .formStyle(.grouped)
      FormButtons(title: t("challenges.start"), enabled: canSave) { save() }
    }
    .padding(20)
    .sheetFrame(width: 500, height: 640)
  }

  private func presetTitle(_ preset: ChallengePreset) -> String {
    if let limit = preset.limit {
      return environment.format(
        "challenges.preset.\(preset.rawValue)", table: ChallengeText.table,
        environment.money.rounded(limit))
    }
    return t("challenges.preset.\(preset.rawValue)")
  }

  private func fill(_ preset: ChallengePreset) {
    title = presetTitle(preset)
    kind = preset.kind
    days = preset.days
    words = preset.keywords.joined(separator: ", ")
    limit = preset.limit ?? .zero
    baseline = .zero
  }

  private func save() -> Bool {
    let planning = compute.snapshot?.ledger.dataset.planning ?? PlanningBook()
    let keywords =
      kind == .noNewSubscriptions
      ? []
      : words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let challenge = Challenge(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, start: startDay,
      end: startDay.adding(days: days - 1),
      categoryIds: kind == .noNewSubscriptions ? [] : categoryId.map { [$0] } ?? [],
      keywords: keywords, limit: kind == .cap ? limit : nil,
      baseline: kind == .noNewSubscriptions || baseline.isZero ? nil : baseline,
      knownSubscriptionIds: kind == .noNewSubscriptions
        ? ChallengeRules.runningSubscriptionIds(in: planning) : [],
      createdOn: environment.today)
    guard (try? environment.challenges?.add(challenge)) != nil else { return false }
    AppLog.info(
      "challenges.started", .db, "a challenge was started",
      [LogPair("days", .count(days))])
    onSaved()
    dismiss()
    return true
  }
}
