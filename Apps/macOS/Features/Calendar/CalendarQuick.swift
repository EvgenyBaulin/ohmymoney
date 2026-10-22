import AppCore
import Observation
import SwiftUI

/// What a drag of an operation carries: its id with a mark, so a drop onto a day of the
/// calendar knows it from any other text.
enum OperationDrag {
  static let mark = "ohmymoney.operation:"

  static func payload(of id: UUID) -> String { mark + id.uuidString }

  static func id(in payload: String) -> UUID? {
    guard payload.hasPrefix(mark) else { return nil }
    return UUID(uuidString: String(payload.dropFirst(mark.count)))
  }
}

/// Makes a row of a list draggable by its operation. Off, the row is untouched.
struct OperationDragModifier: ViewModifier {
  let enabled: Bool
  let id: UUID

  func body(content: Content) -> some View {
    if enabled {
      content.draggable(OperationDrag.payload(of: id))
    } else {
      content
    }
  }
}

// MARK: - Moving an operation to another day

/// An operation moved to another day of the calendar, by a drop on the day or by the menu of
/// the row. The time of day stays, and every check of an edit runs again — the count of the
/// account before it, the rate of the new day, the money left on an archived account — because
/// the move goes through the same editor the inspector uses. One step of ⌘Z.
@MainActor
@Observable
final class MoveToDayModel {
  struct Pick: Identifiable, Equatable {
    var id: UUID
  }

  struct AheadAsk: Identifiable, Equatable {
    var entryId: UUID
    var day: DateOnly
    var id: UUID { entryId }
  }

  /// The sheet that asks for the day (the menu of the row).
  var picking: Pick?
  /// «Этот день ещё не наступил»: the move waits for the owner's word.
  var aheadAsk: AheadAsk?
  /// «Это было до сверки?»: asked by the editor, answered before the move goes on.
  var countQuestion: BeforeTheCountQuestion?
  /// What happened, in words: a notice, or the reason it did not.
  var message: String?
  var failed = false

  @ObservationIgnored private var editor: TransactionEditorModel?

  /// Asks to move `entry` to `day`: checks that it is another day, and a day ahead asks first.
  func request(
    _ entry: TransactionEntry, to day: DateOnly, environment: AppEnvironment,
    store: TransactionsStore, compute: ComputeStore
  ) {
    message = nil
    guard
      let plan = MoveToDay.plan(
        for: entry.transaction, to: day, today: environment.today, calendar: environment.calendar)
    else {
      fail("quick.move.same", environment)
      return
    }
    if plan.isAhead {
      aheadAsk = AheadAsk(entryId: entry.id, day: day)
      return
    }
    perform(entry, plan: plan, environment: environment, store: store, compute: compute)
  }

  /// «Перенести как есть» on a day ahead.
  func confirmAhead(
    _ ask: AheadAsk, entry: TransactionEntry?, environment: AppEnvironment,
    store: TransactionsStore, compute: ComputeStore
  ) {
    aheadAsk = nil
    guard let entry,
      let plan = MoveToDay.plan(
        for: entry.transaction, to: ask.day, today: environment.today,
        calendar: environment.calendar)
    else { return }
    perform(entry, plan: plan, environment: environment, store: store, compute: compute)
  }

  private func perform(
    _ entry: TransactionEntry, plan: MovePlan, environment: AppEnvironment,
    store: TransactionsStore, compute: ComputeStore
  ) {
    let editor = TransactionEditorModel(entry: entry, environment: environment)
    editor.draft.draft.occurredAt = plan.occurredAt
    self.editor = editor
    pending = plan
    save(environment: environment, store: store, compute: compute)
  }

  @ObservationIgnored private var pending: MovePlan?

  /// The save of the move; asked again after an answer about a count.
  private func save(environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore) {
    guard let editor, let plan = pending else { return }
    let balances = compute.snapshot?.planning.accounts.balances
    if editor.save(store: store, environment: environment, balances: balances) {
      var words = [
        QuickText.f("quick.move.done", environment, environment.dates.longDay(plan.toDay))
      ]
      if plan.changesMonth { words.append(QuickText.t("quick.move.month", environment)) }
      if plan.needsRateOfNewDay { words.append(QuickText.t("quick.move.rate", environment)) }
      message = words.joined(separator: " ")
      failed = false
      self.editor = nil
      pending = nil
      return
    }
    if let question = editor.countQuestion {
      countQuestion = question
      return
    }
    fail("quick.move.failed", environment)
    self.editor = nil
    pending = nil
  }

  /// The owner's answers about the counts gave a moment: the move goes on at it.
  func answered(
    _ moment: Date, environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore
  ) {
    countQuestion = nil
    editor?.stampCount(moment)
    save(environment: environment, store: store, compute: compute)
  }

  func cancelCount() {
    countQuestion = nil
    editor = nil
    pending = nil
  }

  private func fail(_ key: String, _ environment: AppEnvironment) {
    message = QuickText.t(key, environment)
    failed = true
  }
}

/// «Перенести на другой день…»: the day is picked in a sheet, for those who do not drag.
struct MoveToDaySheet: View {
  let initial: DateOnly
  let move: (DateOnly) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date

  init(initial: DateOnly, calendar: CalendarContext, move: @escaping (DateOnly) -> Void) {
    self.initial = initial
    self.move = move
    _date = State(initialValue: calendar.moment(initial, hour: 12, minute: 0))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: QuickText.t("quick.move.title", environment)).appFont(.headline)
      DatePicker(
        selection: $date, displayedComponents: .date
      ) {
        Text(verbatim: QuickText.t("quick.move.pick", environment))
      }
      .datePickerStyle(.graphical)
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(QuickText.t("quick.move.confirm", environment)) {
          move(environment.calendar.day(of: date))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("quick.move.confirm")
      }
    }
    .padding(20)
    .sheetFrame(width: 360, height: 420)
  }
}

/// The line under a message of quick entry in the calendar: what was moved, or why not.
struct QuickCalendarMessage: View {
  let text: String
  let failed: Bool

  var body: some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
    }
    .appFont(.callout)
    .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    .accessibilityIdentifier("quick.move.message")
  }
}

// MARK: - The note of a day

/// The note of the chosen day: its text and a button to change it, or the offer to add one. One
/// note per day; saving an empty text deletes it. Each write is one step of ⌘Z.
struct DayNoteRow: View {
  let day: DateOnly
  let note: DayNote?
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @State private var editing = false
  @State private var failed = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "note.text")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      if let note {
        Text(verbatim: note.text)
          .appFont(.callout)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        Button(QuickText.t("quick.note.edit", environment)) { editing = true }
          .buttonStyle(.link)
          .appFont(.caption)
          .accessibilityIdentifier("quick.note.edit")
      } else {
        Button(QuickText.t("quick.note.add", environment)) { editing = true }
          .buttonStyle(.link)
          .appFont(.callout)
          .accessibilityIdentifier("quick.note.add")
      }
    }
    .accessibilityElement(children: .contain)
    .sheet(isPresented: $editing) {
      DayNoteSheet(day: day, text: note?.text ?? "", hasNote: note != nil) { text in
        failed = !store.setDayNote(text, on: day)
        return !failed
      }
    }
    .refusedWriteAlert($failed, environment)
  }
}

struct DayNoteSheet: View {
  let day: DateOnly
  let hasNote: Bool
  /// Writes the text (empty deletes); whether it landed.
  let save: (String) -> Bool
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var text: String

  init(day: DateOnly, text: String, hasNote: Bool, save: @escaping (String) -> Bool) {
    self.day = day
    self.hasNote = hasNote
    self.save = save
    _text = State(initialValue: text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: QuickText.t("quick.note.title", environment)).appFont(.headline)
      Text(verbatim: environment.dates.longDay(day))
        .appFont(.callout).foregroundStyle(.secondary)
      TextField(
        text: $text, axis: .vertical
      ) {
        Text(verbatim: QuickText.t("quick.note.placeholder", environment))
      }
      .lineLimit(3...6)
      .textFieldStyle(.roundedBorder)
      .onChange(of: text) { _, new in
        if new.count > DayNote.maxLength { text = String(new.prefix(DayNote.maxLength)) }
      }
      .accessibilityIdentifier("quick.note.field")
      HStack {
        if hasNote {
          Button(QuickText.t("quick.note.delete", environment), role: .destructive) {
            if save("") { dismiss() }
          }
        }
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(QuickText.t("quick.note.save", environment)) {
          if save(text) { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("quick.note.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 260)
  }
}

/// The sheet, the question about a day ahead and the question about a count of a move to
/// another day, hung once on the screen that moves operations.
struct MoveToDayPresentation: ViewModifier {
  let mover: MoveToDayModel
  let snapshot: DataSnapshot
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  func body(content: Content) -> some View {
    content
      .sheet(
        item: Binding(get: { mover.picking }, set: { mover.picking = $0 })
      ) { pick in
        if let entry = snapshot.ledger.entry(pick.id) {
          MoveToDaySheet(
            initial: environment.calendar.day(of: entry.transaction.occurredAt),
            calendar: environment.calendar
          ) { day in
            mover.request(
              entry, to: day, environment: environment, store: store, compute: compute)
          }
          .handingOver(dependencies)
        }
      }
      .confirmationDialog(
        QuickText.t("quick.move.ahead.title", environment),
        isPresented: Binding(
          get: { mover.aheadAsk != nil }, set: { if !$0 { mover.aheadAsk = nil } }),
        titleVisibility: .visible, presenting: mover.aheadAsk
      ) { ask in
        Button(QuickText.t("quick.move.ahead.record", environment)) {
          mover.confirmAhead(
            ask, entry: snapshot.ledger.entry(ask.entryId), environment: environment,
            store: store, compute: compute)
        }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: QuickText.t("quick.move.ahead.message", environment))
      }
      .beforeTheCountQuestions(
        // Closing the dialog saves nothing and leaves the editor to the next move; the walk sets
        // the next count's question itself.
        Binding(get: { mover.countQuestion }, set: { mover.countQuestion = $0 })
      ) { moment in
        mover.answered(moment, environment: environment, store: store, compute: compute)
      }
  }
}
