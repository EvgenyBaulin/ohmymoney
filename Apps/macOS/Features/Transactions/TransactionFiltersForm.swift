import AppCore
import SwiftUI

/// The filters of «Операции», in the popover of its «Фильтры» button: a grouped form, every
/// choice with its label.
struct TransactionFiltersForm: View {
  @Dependency(\.environment) private var environment
  @Binding var filters: TransactionFilters
  let choices: FilterChoices

  var body: some View {
    Form {
      Section {
        Picker(selection: $filters.period) {
          ForEach(TransactionFilters.PeriodChoice.allCases, id: \.self) { item in
            Text(verbatim: t(item.titleKey)).tag(item)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.inline)
        if filters.period == .custom {
          // Dates in the language of the app: the window's locale is set at its root.
          DatePicker(selection: day(\.customStart), displayedComponents: .date) {
            Text(verbatim: t("filters.from"))
          }
          DatePicker(selection: day(\.customEnd), displayedComponents: .date) {
            Text(verbatim: t("filters.to"))
          }
        }
      } header: {
        Text(verbatim: t("filters.period"))
      }

      Section {
        OptionalPicker(
          title: t("filters.type"), any: any, selection: kind,
          options: TransactionKind.allCases.map {
            ($0, environment.language("kind.\($0.rawValue)"))
          })
        OptionalPicker(
          title: entry("entry.category"), any: any, selection: category,
          options: choices.topLevel(for: filters.kind).map { ($0.id, $0.name) })
        OptionalPicker(
          title: entry("entry.subcategory"), any: any, selection: $filters.subcategoryId,
          options: choices.subcategories(of: filters.categoryId).map { ($0.id, $0.name) }
        )
        .disabled(choices.subcategories(of: filters.categoryId).isEmpty)
        OptionalPicker(
          title: entry("entry.quality"), any: any, selection: $filters.quality,
          options: Quality.allCases.map { ($0, environment.language(Palette.qualityKey($0))) })
        OptionalPicker(
          title: entry("entry.forWhom"), any: any, selection: $filters.forWhom,
          options: ForWhom.allCases.map { ($0, environment.label(for: $0)) })
        // An archived person, place or event stays in its operations, so the filter still
        // finds them: after the live ones, named «(архив)».
        let people = choices.personOptions(archivedName: archivedName)
        OptionalPicker(
          title: t("filters.person"), any: any, selection: $filters.personId,
          options: people.options, dividerBefore: people.dividerBefore)
        let places = choices.placeOptions(archivedName: archivedName)
        OptionalPicker(
          title: entry("entry.place"), any: any, selection: $filters.placeId,
          options: places.options, dividerBefore: places.dividerBefore)
        let events = choices.eventOptions(archivedName: archivedName)
        OptionalPicker(
          title: entry("entry.event"), any: any, selection: $filters.eventId,
          options: events.options, dividerBefore: events.dividerBefore)
        // An account finds every operation of it and its cards; a card only what it paid.
        OptionalPicker(
          title: entry("entry.paymentMethod"), any: any, selection: accountOrCard,
          options: choices.accountItems.map { ($0.id, $0.name) })
        OptionalPicker(
          title: t("filters.status"), any: any, selection: $filters.status,
          options: ReimbursementStatus.allCases.map {
            ($0, environment.language(Palette.reimbursementKey($0)))
          })
      } header: {
        Text(verbatim: t("filters.title"))
      }

      Section {
        // Filters and search alike; inactive when there is nothing to reset.
        Button(t("filters.reset")) { filters.reset() }
          .disabled(!filters.canReset)
      }
    }
    .formStyle(.grouped)
  }

  /// The type narrows the categories to its kind and drops one of the other kind.
  private var kind: Binding<TransactionKind?> {
    Binding(
      get: { filters.kind },
      set: { filters.setKind($0, tree: choices.categories) })
  }

  /// An account, or one of its cards.
  private var accountOrCard: Binding<UUID?> {
    Binding(
      get: { filters.accountOrCard },
      set: { filters.setAccountOrCard($0, cards: choices.cards) })
  }

  /// Another category drops the subcategory.
  private var category: Binding<UUID?> {
    Binding(
      get: { filters.categoryId },
      set: { filters.setCategory($0) })
  }

  /// A day of the custom range as a date picker edits it: the start of the day in the app's
  /// calendar.
  private func day(_ path: WritableKeyPath<TransactionFilters, DateOnly>) -> Binding<Date> {
    let calendar = environment.calendar
    return Binding(
      get: { calendar.startOfDay(filters[keyPath: path]) },
      set: { filters[keyPath: path] = calendar.day(of: $0) })
  }

  private var any: String { t("filters.any") }
  private func archivedName(_ name: String) -> String {
    environment.format("common.archivedName", name)
  }
  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
  private func entry(_ key: String) -> String { environment.language(key, table: "Entry") }
}

/// A picker of one value or «Any»; `dividerBefore` sets a line apart before that option (the
/// archived ones after the live ones).
private struct OptionalPicker<Value: Hashable>: View {
  let title: String
  let any: String
  @Binding var selection: Value?
  let options: [(Value, String)]
  var dividerBefore: Int? = nil

  var body: some View {
    Picker(selection: $selection) {
      Text(verbatim: any).tag(Value?.none)
      ForEach(options.indices, id: \.self) { index in
        if index == dividerBefore, index > 0 { Divider() }
        Text(verbatim: options[index].1).tag(Value?.some(options[index].0))
      }
    } label: {
      Text(verbatim: title)
    }
  }
}

extension Notification.Name {
  /// Carries the section number of ⌘1 / ⌘2 / ⌘3.
  static let selectSection = Notification.Name("io.github.EvgenyBaulin.ohmymoney.selectSection")
}

/// The editor of an operation in the column beside the table of «Операции». It takes the
/// dependencies in its initializer and hands them to the editor itself, as everything laid out in
/// a host of its own must (the crash of 19.09 in an inspector without the window's environment).
struct TransactionInspector: View {
  let deps: AppDependencies
  let editor: TransactionEditorModel
  let close: () -> Void

  var body: some View {
    TransactionEditor(editor: editor, style: .inspector, close: close)
      // The column gives it a width of its own and nothing more: without its ideal said again
      // here the editor asks for what its widest row would like — 418 pt in English, 552 in
      // Russian. Its kinds and «За кого» are menus, not segments wider than the column
      // (`hasRoomForSegments`), so its minimum stays under the column's whatever scroll bars the
      // Mac shows; a split view that once took that minimum back looped (11.10).
      .frame(idealWidth: TransactionInspector.idealWidth)
      .appDependencies(deps)
  }

  /// The width of the column of the editor beside the table of «Операции», and the narrowest
  /// its content may ask for.
  static let idealWidth: CGFloat = 360
  static let minimumWidth: CGFloat = 300
}
