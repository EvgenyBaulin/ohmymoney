import AppCore
import AppDatabase
import SwiftUI

/// People, places and events — the dictionaries the entry line matches names against — and
/// everything each of them carries: the other names and the relation of a person, the other
/// names of a place, the dates, budget and yearly repeat of an event.
/// Accounts have a tab of their own.
///
/// A row nothing points at — no operation, the ones in the bin included, no plan, no debt —
/// can be deleted, for good. A row something points at is merged into another (its operations
/// move and its name becomes an other name there) or put in the archive, which the list shows
/// when asked, each row with «Вернуть». Neither a merge nor a deletion can be taken back, so
/// both are asked first. Several rows can be picked at once to delete the unused ones.
struct ReferenceBooksView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  @State private var book: Book = .people
  /// Every row of each book, the archived ones too; the list shows the archive when asked.
  @State private var people: [Person] = []
  @State private var places: [Place] = []
  @State private var events: [Event] = []
  /// What points at each used row of the book on screen. A row that is not here is used by
  /// nothing and can be deleted.
  @State private var usage: [UUID: ReferenceUsage] = [:]
  @State private var selection: Set<UUID> = []
  @State private var showsArchive = false
  @State private var newName = ""
  /// The merge the owner picked from a row's menu, waiting for the answer.
  @State private var merging: MergeQuestion?
  /// The deletion the owner asked for, waiting for the answer.
  @State private var deleting: DeleteQuestion?
  /// Said under the list: why the last action did less than was asked.
  @State private var note: String?
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  enum Book: String, CaseIterable, Identifiable {
    case people, places, events
    var id: String { rawValue }

    var titleKey: String {
      switch self {
      case .people: "settings.people"
      case .places: "settings.places"
      case .events: "settings.events"
      }
    }

    /// The dictionary the repository keeps it in.
    var stored: ReferenceBook {
      switch self {
      case .people: .people
      case .places: .places
      case .events: .events
      }
    }
  }

  /// A line of the list. An event carries its days: a yearly event is made again every year
  /// under the same name, and only the days tell those apart.
  struct Row: Identifiable, Hashable {
    let id: UUID
    let name: String
    let archived: Bool
    var days: String? = nil

    /// How the row is named wherever it is picked or asked about: the list, «Объединить с…»,
    /// the questions before a merge or a deletion.
    var title: String {
      guard let days, !days.isEmpty else { return name }
      return "\(name) · \(days)"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Picker(selection: $book) {
          ForEach(Book.allCases) { item in
            Text(verbatim: t(item.titleKey)).tag(item)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer(minLength: 0)
        Toggle(isOn: $showsArchive) {
          Text(verbatim: t("references.showArchive"))
        }
        .toggleStyle(.checkbox)
      }

      HStack(alignment: .top, spacing: 12) {
        list
          .frame(width: 240)
        Divider()
        detail
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let note {
        Label {
          Text(verbatim: note)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }

      HStack {
        TextField(text: $newName) {
          Text(verbatim: t("references.name"))
        }
        .onSubmit(add)
        Button(t("references.add"), action: add)
          .disabled(!canAddNewName)
      }
      if isNewNameTaken {
        Text(verbatim: t("references.nameTaken"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
    .onChange(of: book) { _, _ in
      selection = []
      note = nil
      reload()
    }
    .onChange(of: showsArchive) { _, isShown in
      // A row the list no longer shows is no longer picked.
      if !isShown { selection.subtract(rows.filter(\.archived).map(\.id)) }
    }
    .confirmationDialog(
      merging?.title(environment) ?? "", isPresented: isAskingToMerge,
      titleVisibility: .visible, presenting: merging
    ) { question in
      Button(question.confirm(environment), role: .destructive) { merge(question) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: question.message(environment))
    }
    .confirmationDialog(
      deleting?.title(environment) ?? "", isPresented: isAskingToDelete,
      titleVisibility: .visible, presenting: deleting
    ) { question in
      Button(environment.language("action.delete"), role: .destructive) { delete(question) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: question.message(environment))
    }
  }

  private var isAskingToMerge: Binding<Bool> {
    Binding(
      get: { merging != nil },
      set: { isShown in
        if !isShown { merging = nil }
      })
  }

  private var isAskingToDelete: Binding<Bool> {
    Binding(
      get: { deleting != nil },
      set: { isShown in
        if !isShown { deleting = nil }
      })
  }

  /// A merge of one row into another, asked before it is made: the operations move and the
  /// row merged away goes to the archive, and nothing takes that back.
  struct MergeQuestion: Identifiable {
    let book: Book
    let source: UUID
    let sourceName: String
    let target: UUID
    let targetName: String

    var id: UUID { source }

    @MainActor
    func title(_ environment: AppEnvironment) -> String {
      environment.format("references.merge.title", table: "Settings", sourceName, targetName)
    }

    /// An event has no other names: its old name does not stay anywhere.
    @MainActor
    func message(_ environment: AppEnvironment) -> String {
      environment.format(
        book == .events ? "references.merge.messageEvent" : "references.merge.message",
        table: "Settings", sourceName, targetName)
    }

    @MainActor
    func confirm(_ environment: AppEnvironment) -> String {
      environment.language("references.merge.confirm", table: "Settings")
    }

    /// Makes the merge the owner agreed to.
    func merge(_ references: ReferenceRepository) throws {
      switch book {
      case .people: try references.mergePerson(source, into: target)
      case .places: try references.mergePlace(source, into: target)
      case .events: try references.mergeEvent(source, into: target)
      }
    }
  }

  /// Rows nothing points at, about to be deleted for good, asked first; `skipped` rows were
  /// picked with them but are used, and stay.
  struct DeleteQuestion: Identifiable {
    let ids: [UUID]
    let names: [String]
    let skipped: Int

    var id: [UUID] { ids }

    @MainActor
    func title(_ environment: AppEnvironment) -> String {
      if ids.count == 1, let name = names.first {
        return environment.format("references.delete.title", table: "Settings", name)
      }
      return environment.format("references.delete.titleMany", table: "Settings", counts: ids.count)
    }

    @MainActor
    func message(_ environment: AppEnvironment) -> String {
      var lines = [
        environment.language(
          ids.count == 1 ? "references.delete.message" : "references.delete.messageMany",
          table: "Settings")
      ]
      if skipped > 0 {
        lines.append(
          environment.format("references.delete.skipped", table: "Settings", counts: skipped))
      }
      return lines.joined(separator: " ")
    }
  }

  // MARK: List

  private var list: some View {
    List(selection: $selection) {
      Section {
        ForEach(rows.filter { !$0.archived }) { row in
          rowView(row)
        }
      }
      let archived = rows.filter(\.archived)
      if showsArchive, !archived.isEmpty {
        Section {
          ForEach(archived) { row in
            rowView(row)
          }
        } header: {
          Text(verbatim: t("references.archiveSection"))
            .settingsHeaderStyle()
        }
      }
    }
    .frame(minHeight: 240)
  }

  private func rowView(_ row: Row) -> some View {
    HStack(spacing: 6) {
      if row.archived {
        Image(systemName: "archivebox")
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text(verbatim: t("references.inArchive")))
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: row.name)
          .foregroundStyle(row.archived ? .secondary : .primary)
          .lineLimit(1)
        if let days = row.days {
          Text(verbatim: days)
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      Menu {
        menuItems(row)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(
            Text(
              verbatim: environment.format(
                "references.rowMenu", table: "Settings", row.title)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(t("references.rowMenuHint"))
    }
    .tag(row.id)
    .contextMenu { menuItems(row) }
  }

  /// The same items in the visible «…» of a row and in its context menu. «Удалить…» is there
  /// only while nothing points at the row.
  @ViewBuilder
  private func menuItems(_ row: Row) -> some View {
    if row.archived {
      Button(t("references.restore")) { restore(row) }
    }
    let targets = mergeTargets(excluding: row.id)
    if !targets.isEmpty {
      Menu(t("references.merge")) {
        ForEach(targets) { target in
          Button(target.title) {
            merging = MergeQuestion(
              book: book, source: row.id, sourceName: row.title, target: target.id,
              targetName: target.title)
          }
        }
      }
    }
    if !row.archived {
      Button(t("references.archive")) { archive(row.id) }
    }
    if !isUsed(row.id) {
      Divider()
      Button(t("references.deleteAsk"), role: .destructive) { askToDelete([row]) }
    }
  }

  /// Every row of the book on screen: the live ones, then those in the archive.
  private var rows: [Row] {
    let environment = environment
    return Self.rows(
      of: book, people: people, places: places, events: events,
      days: { Self.days(of: $0, in: environment) })
  }

  /// `days` words the days of an event; people and places have none.
  static func rows(
    of book: Book, people: [Person], places: [Place], events: [Event],
    days: (Event) -> String = { _ in "" }
  ) -> [Row] {
    let all: [Row] =
      switch book {
      case .people: people.map { Row(id: $0.id, name: $0.name, archived: $0.archived) }
      case .places: places.map { Row(id: $0.id, name: $0.name, archived: $0.archived) }
      case .events:
        events.map { Row(id: $0.id, name: $0.name, archived: $0.archived, days: days($0)) }
      }
    return all.filter { !$0.archived } + all.filter(\.archived)
  }

  /// The days of an event with their year, as short as the language allows: «1–3 янв. 2026 г.»,
  /// «Jan 1 – 3, 2026».
  static func days(of event: Event, in environment: AppEnvironment) -> String {
    let formatter = DateIntervalFormatter()
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.locale = environment.language.locale
    gregorian.timeZone = environment.calendar.timeZone
    formatter.calendar = gregorian
    formatter.locale = environment.language.locale
    formatter.timeZone = environment.calendar.timeZone
    formatter.dateTemplate = "d MMM y"
    return formatter.string(
      from: environment.calendar.startOfDay(event.startDate),
      to: environment.calendar.startOfDay(max(event.startDate, event.endDate)))
  }

  /// Rows are merged into live rows only: the archive is where a merged row goes.
  private func mergeTargets(excluding id: UUID) -> [Row] {
    rows.filter { $0.id != id && !$0.archived }
  }

  private func isUsed(_ id: UUID) -> Bool { usage[id]?.isUsed ?? false }

  // MARK: Detail

  @ViewBuilder
  private var detail: some View {
    let chosen = rows.filter { selection.contains($0.id) }
    if chosen.count > 1 {
      several(chosen)
    } else if let row = chosen.first {
      switch book {
      case .people:
        if let index = people.firstIndex(where: { $0.id == row.id }) { personForm(index) }
      case .places:
        if let index = places.firstIndex(where: { $0.id == row.id }) { placeForm(index) }
      case .events:
        if let index = events.firstIndex(where: { $0.id == row.id }) { eventForm(index) }
      }
    } else {
      Text(verbatim: t("references.pick"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
    }
  }

  private func personForm(_ index: Int) -> some View {
    let person = people[index]
    return VStack(alignment: .leading, spacing: 8) {
      Form {
        Section {
          TextField(text: $people[index].name) { label("references.name") }
          Picker(selection: $people[index].relation) {
            ForEach(PersonRelation.allCases, id: \.self) { relation in
              Text(verbatim: t("relation.\(relation.rawValue)")).tag(relation)
            }
          } label: {
            label("references.relation")
          }
        }
        PersonGiftFields(person: $people[index])
        // Its own editor for each row: a name typed and not added stays with the row it was
        // typed for, and so does the reason one was refused.
        OtherNamesEditor(
          names: $people[index].aliases, ownName: person.name,
          owner: { owner(of: $0, excluding: person.id) }
        )
        .id(person.id)
        status(of: row(person.id, person.name, person.archived))
      }
      .formStyle(.grouped)
      saveRow(
        refusal: Self.refusal(
          saving: person.name, otherNames: person.aliases, id: person.id, in: .people,
          among: spellings)
      ) { references in
        var tidied = people[index]
        tidied.name = tidied.name.trimmingCharacters(in: .whitespaces)
        tidied.aliases = Self.tidied(tidied.aliases, name: tidied.name)
        try references.save(tidied)
      }
    }
  }

  private func placeForm(_ index: Int) -> some View {
    let place = places[index]
    return VStack(alignment: .leading, spacing: 8) {
      Form {
        Section {
          TextField(text: $places[index].name) { label("references.name") }
        }
        OtherNamesEditor(
          names: $places[index].aliases, ownName: place.name,
          owner: { owner(of: $0, excluding: place.id) }
        )
        .id(place.id)
        status(of: row(place.id, place.name, place.archived))
      }
      .formStyle(.grouped)
      saveRow(
        refusal: Self.refusal(
          saving: place.name, otherNames: place.aliases, id: place.id, in: .places,
          among: spellings)
      ) { references in
        var tidied = places[index]
        tidied.name = tidied.name.trimmingCharacters(in: .whitespaces)
        tidied.aliases = Self.tidied(tidied.aliases, name: tidied.name)
        try references.save(tidied)
      }
    }
  }

  private func eventForm(_ index: Int) -> some View {
    let event = events[index]
    return VStack(alignment: .leading, spacing: 8) {
      Form {
        Section {
          TextField(text: $events[index].name) { label("references.name") }
          Picker(selection: $events[index].kind) {
            ForEach(EventKind.allCases, id: \.self) { kind in
              Text(verbatim: t("event.\(kind.rawValue)")).tag(kind)
            }
          } label: {
            label("references.kind")
          }
          // The pickers are shared by every event picked here: the end one is made anew for
          // each, or it kept showing the day of the event picked before.
          EventDaysFields(
            owner: event.id, start: $events[index].startDate, end: $events[index].endDate,
            startLabel: t("references.start"), endLabel: t("references.end")
          )
          .environment(\.locale, environment.language.locale)
          LabeledContent {
            AmountField(amount: budgetBinding(index), locale: environment.language.locale)
              .frame(width: 140)
          } label: {
            label("references.budget")
          }
          Toggle(isOn: $events[index].recurringYearly) { label("references.yearly") }
        }
        status(
          of: Row(
            id: event.id, name: event.name, archived: event.archived,
            days: Self.days(of: event, in: environment)))
      }
      .formStyle(.grouped)
      saveRow(
        refusal: Self.refusal(
          saving: event.name, otherNames: [], id: event.id, in: .events, among: spellings)
      ) { references in
        var tidied = events[index]
        tidied.name = tidied.name.trimmingCharacters(in: .whitespaces)
        try references.save(tidied)
      }
    }
  }

  private func row(_ id: UUID, _ name: String, _ archived: Bool) -> Row {
    Row(id: id, name: name, archived: archived)
  }

  /// Whether the row is in the archive, with «Вернуть», and what points at it — which says
  /// why «Удалить» is or is not in its menu. A live row says what the archive does to it — gone
  /// from entry and the lists, kept by its operations, Analytics and Reports — and has its own
  /// «В архив», used or not.
  private func status(of row: Row) -> some View {
    Section {
      if row.archived {
        HStack {
          Label {
            Text(verbatim: t("references.inArchive"))
          } icon: {
            Image(systemName: "archivebox")
          }
          Spacer()
          Button(t("references.restore")) { restore(row) }
        }
      }
      Text(verbatim: usageText(row.id))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !row.archived {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: t(Self.archiveHintKey(book)))
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button(t("references.archive")) { archive(row.id) }
        }
      }
    }
  }

  /// What the archive does to a row of the book, in words (table Settings).
  static func archiveHintKey(_ book: Book) -> String {
    switch book {
    case .people: "references.archiveHint.people"
    case .places: "references.archiveHint.places"
    case .events: "references.archiveHint.events"
    }
  }

  /// «Используется: 12 операций, 1 запись планирования…» or «Ни на что не ссылается…».
  private func usageText(_ id: UUID) -> String {
    guard let used = usage[id], used.isUsed else { return t("references.usage.none") }
    var parts: [String] = []
    if used.operations > 0 {
      parts.append(
        environment.format(
          "references.usage.operations", table: "Settings", counts: used.operations))
    }
    if used.planning > 0 {
      parts.append(
        environment.format("references.usage.planning", table: "Settings", counts: used.planning))
    }
    return environment.format(
      "references.usage.used", table: "Settings", parts.joined(separator: ", "))
  }

  /// Several rows picked: the unused ones can be deleted together, the used ones are named
  /// by their number and stay.
  private func several(_ chosen: [Row]) -> some View {
    let unused = chosen.filter { !isUsed($0.id) }
    let used = chosen.count - unused.count
    return VStack(alignment: .leading, spacing: 10) {
      Text(
        verbatim: environment.format("references.selected", table: "Settings", counts: chosen.count)
      )
      .appFont(.headline)
      if used > 0 {
        Label {
          Text(
            verbatim: environment.format(
              "references.selectedUsed", table: "Settings", counts: used)
          )
          .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
      Button(
        environment.format("references.deleteUnused", table: "Settings", counts: unused.count),
        role: .destructive
      ) {
        askToDelete(unused, skipped: used)
      }
      .disabled(unused.isEmpty)
    }
    .padding(.top, 20)
  }

  // MARK: Pieces

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key))
  }

  /// «Сохранить», and above it why the form cannot be saved as it is. A refused write keeps the
  /// form as the owner left it, so pressing «Сохранить» again is the retry.
  private func saveRow(
    refusal: SaveRefusal?, _ save: @escaping (ReferenceRepository) throws -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      if let refusal {
        Label {
          Text(verbatim: message(refusal))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(environment.language("action.save")) {
        guard environment.attempt("references.save", on: environment.references, save) else {
          refused = true
          return
        }
        finish()
      }
      .buttonStyle(.borderedProminent)
      .disabled(refusal != nil)
    }
    .padding(.horizontal)
  }

  private func message(_ refusal: SaveRefusal) -> String {
    switch refusal {
    case .emptyName: t("references.refusal.emptyName")
    case .nameTaken(let other):
      environment.format("references.refusal.nameTaken", table: "Settings", other)
    case .otherNameTaken(let name, let other):
      environment.format("references.refusal.otherNameTaken", table: "Settings", name, other)
    }
  }

  private func budgetBinding(_ index: Int) -> Binding<AmountE4> {
    Binding(
      get: { events[index].budgetE4 ?? .zero },
      set: { events[index].budgetE4 = $0.isZero ? nil : $0 })
  }

  // MARK: Names

  /// The names the entry line knows in each book: every live row's name and other names.
  private var spellings: Spellings {
    Spellings(people: people, places: places)
  }

  /// The live rows of the people and the places, each with every name it answers to.
  struct Spellings {
    var people: [Person] = []
    var places: [Place] = []

    func rows(of book: Book) -> [(id: UUID, name: String, names: [String])] {
      switch book {
      case .people:
        people.filter { !$0.archived }.map { ($0.id, $0.name, ReferenceNames.spellings($0)) }
      case .places:
        places.filter { !$0.archived }.map { ($0.id, $0.name, ReferenceNames.spellings($0)) }
      case .events: []
      }
    }

    /// The name of the live row but `id` that answers to `name`; nil when none does.
    func owner(of name: String, in book: Book, excluding id: UUID) -> String? {
      let wanted = ReferenceNames.folded(name)
      guard !wanted.isEmpty else { return nil }
      return rows(of: book).first { row in
        row.id != id && row.names.contains { ReferenceNames.folded($0) == wanted }
      }?.name
    }
  }

  private func owner(of name: String, excluding id: UUID) -> String? {
    spellings.owner(of: name, in: book, excluding: id)
  }

  /// Why a row cannot be saved under these names.
  enum SaveRefusal: Equatable {
    case emptyName
    /// The name is another live row's name or other name; the value is that row's name.
    case nameTaken(String)
    /// One of the other names is another live row's; the name, then that row's name.
    case otherNameTaken(String, String)
  }

  /// Why the row `id` of `book` cannot be saved with `name` and `otherNames`, or nil when it
  /// can. A name has to say something. A person or a place may not take a name — its own or an
  /// other one — another live row answers to: the entry line could not tell the two apart.
  /// Events may share a name: a yearly event is made again every year under it.
  static func refusal(
    saving name: String, otherNames: [String], id: UUID, in book: Book, among spellings: Spellings
  ) -> SaveRefusal? {
    guard !ReferenceNames.folded(name).isEmpty else { return .emptyName }
    guard book != .events else { return nil }
    if let other = spellings.owner(of: name, in: book, excluding: id) {
      return .nameTaken(other)
    }
    for otherName in otherNames {
      if let other = spellings.owner(of: otherName, in: book, excluding: id) {
        return .otherNameTaken(otherName, other)
      }
    }
    return nil
  }

  /// Other names as they are stored: without the spaces around them, each once, never the
  /// row's own name, never empty.
  static func tidied(_ otherNames: [String], name: String) -> [String] {
    var seen: Set<String> = [ReferenceNames.folded(name)]
    var kept: [String] = []
    for otherName in otherNames {
      let trimmed = otherName.trimmingCharacters(in: .whitespaces)
      let key = ReferenceNames.folded(trimmed)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      kept.append(trimmed)
    }
    return kept
  }

  // MARK: Data

  private func reload() {
    guard let references = environment.references else { return }
    people = (try? references.people(includeArchived: true)) ?? []
    places = (try? references.places(includeArchived: true)) ?? []
    events = (try? references.events(includeArchived: true)) ?? []
    usage = (try? references.usage(in: book.stored)) ?? [:]
    // A row gone — deleted here, merged, or by another window — is no longer picked.
    selection.formIntersection(rows.map(\.id))
  }

  private var canAddNewName: Bool {
    Self.canAdd(newName, to: book, people: people, places: places)
  }

  /// The name is not empty and still cannot be added: say why the button is grey.
  private var isNewNameTaken: Bool {
    !ReferenceNames.folded(newName).isEmpty && !canAddNewName
  }

  private var actions: ReferenceBookActions {
    ReferenceBookActions(environment: environment, store: store)
  }

  /// A new row, or the one the archive holds under this name. A refused add keeps the name in
  /// the field.
  private func add() {
    guard canAddNewName else { return }
    guard let added = actions.add(newName, to: book.stored) else {
      refused = true
      return
    }
    newName = ""
    note = nil
    reload()
    selection = [added]
  }

  private func merge(_ question: MergeQuestion) {
    merging = nil
    guard actions.merge(question) == .done else {
      refused = true
      return
    }
    selection = []
    reload()
  }

  private func archive(_ id: UUID) {
    switch actions.archive(id, in: book.stored) {
    case .done, .gone:
      if !showsArchive { selection.remove(id) }
    case .refused, .nameTaken:
      refused = true
    }
    reload()
  }

  /// «Вернуть». A person or a place whose name a live row has taken meanwhile stays in the
  /// archive, and the note under the list says so.
  private func restore(_ row: Row) {
    switch actions.restore(row.id, in: book.stored) {
    case .done, .gone:
      note = nil
    case .nameTaken:
      note = environment.format("references.restore.nameTaken", table: "Settings", row.title)
    case .refused:
      refused = true
    }
    reload()
  }

  private func askToDelete(_ chosen: [Row], skipped: Int = 0) {
    guard !chosen.isEmpty else { return }
    deleting = DeleteQuestion(ids: chosen.map(\.id), names: chosen.map(\.title), skipped: skipped)
  }

  private func delete(_ question: DeleteQuestion) {
    deleting = nil
    guard let result = actions.delete(question.ids, from: book.stored) else {
      refused = true
      return
    }
    selection.subtract(result.deleted)
    note =
      result.kept.isEmpty
      ? nil
      : environment.format("references.delete.kept", table: "Settings", counts: result.kept.count)
    reload()
  }

  /// After «Сохранить» of a form.
  private func finish() {
    reload()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }
}

/// What the reference books write, apart from the view that asks: a new row or one brought
/// back from the archive, a merge, the archive and «Вернуть», and deleting what nothing points
/// at. After every write the entry line learns the names again and a backup is due.
@MainActor
struct ReferenceBookActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  enum Outcome: Equatable {
    case done
    /// The database refused the write, or is not open; the screen says so.
    case refused
    /// «Вернуть» of a person or a place whose name a live row has taken meanwhile: it stays
    /// in the archive.
    case nameTaken
    /// The row is not there any more — another window deleted it.
    case gone
  }

  /// «Добавить»: the row the archive holds under `name` comes back, otherwise a new one is
  /// written — a new event starts and ends today. Its id; nil when the write was refused.
  func add(_ name: String, to book: ReferenceBook) -> UUID? {
    let today = environment.today
    var added: UUID?
    let written = environment.attempt("references.add", on: environment.references) {
      added = try NewReference.add(name, to: book, from: today, to: today, references: $0)
    }
    guard written, let added else { return nil }
    refreshed()
    return added
  }

  /// A merge the owner agreed to: the operations move, the name becomes an other name of the
  /// row that stays, the row merged away goes to the archive. Asked, not undone — and the ⌘Z
  /// history is forgotten: a step taken before would put an operation back on the row merged
  /// away.
  func merge(_ question: ReferenceBooksView.MergeQuestion) -> Outcome {
    guard
      environment.attempt(
        "references.merge", on: environment.references, { try question.merge($0) })
    else { return .refused }
    store.forgetUndoHistory()
    refreshed()
    return .done
  }

  /// «В архив»: only the flag is written, whatever the form of the row holds unsaved.
  func archive(_ id: UUID, in book: ReferenceBook) -> Outcome {
    write("references.archive") { try $0.archive(id, in: book) }
  }

  /// «Вернуть»: the row is live again, its other names a live row took meanwhile dropped.
  func restore(_ id: UUID, in book: ReferenceBook) -> Outcome {
    write("references.restore") { try $0.restore(id, in: book) }
  }

  /// Deletes for good the rows of `ids` nothing points at — the operations in the bin count —
  /// checked again inside the write, since something may have come to point at a row since
  /// the question. Nil when the write was refused. There is no step of ⌘Z for it, and the ⌘Z
  /// history is forgotten, as after every write ⌘Z cannot describe: a step taken before could
  /// bring back an operation naming a deleted row.
  func delete(_ ids: [UUID], from book: ReferenceBook) -> ReferenceDeletion? {
    var result = ReferenceDeletion()
    let written = environment.attempt("references.delete", on: environment.references) {
      result = try $0.delete(ids, from: book)
    }
    guard written else { return nil }
    if !result.deleted.isEmpty {
      store.forgetUndoHistory()
      AppLog.info(
        "references.deleted", .db, "unused rows of a reference book were deleted",
        [
          LogPair("book", .token(book.rawValue)), LogPair("deleted", .count(result.deleted.count)),
          LogPair("kept", .count(result.kept.count)),
        ])
      refreshed()
    }
    return result
  }

  private func write(
    _ name: String, _ body: (ReferenceRepository) throws -> Void
  ) -> Outcome {
    guard let references = environment.references else {
      AppLog.error(name, .db, "no database to write to", [LogPair("reason", .token("noDatabase"))])
      return .refused
    }
    do {
      try body(references)
    } catch ReferenceWriteError.nameTaken {
      return .nameTaken
    } catch ReferenceWriteError.notFound {
      return .gone
    } catch {
      AppLog.error(name, .db, "a write was refused", [LogPair("error", .error(error))])
      return .refused
    }
    refreshed()
    return .done
  }

  private func refreshed() {
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }
}

extension ReferenceBooksView {
  /// Whether a new row of `book` may be called `name`. A person or a place whose name or other
  /// name is already a live row's adds nothing: two rows with one name are two rows the entry
  /// line cannot tell apart. A name the archive holds may be added — «Добавить» brings that
  /// row back. Events are the exception — a yearly event is made again under the same name
  /// every year, so a shared name is how they are meant to be, and the entry line tells them
  /// apart by their dates.
  static func canAdd(
    _ name: String, to book: Book, people: [Person], places: [Place]
  ) -> Bool {
    guard !ReferenceNames.folded(name).isEmpty else { return false }
    switch book {
    case .people:
      return !ReferenceNames.isTaken(
        name, among: people.filter { !$0.archived }.map(ReferenceNames.spellings))
    case .places:
      return !ReferenceNames.isTaken(
        name, among: places.filter { !$0.archived }.map(ReferenceNames.spellings))
    case .events: return true
    }
  }
}

/// The one rule of «this name is taken», shared by the reference books, the accounts added
/// from the ↓ panel and the General tab.
///
/// It compares names the way the entry line reads them: case, «ё» against «е» and the spaces
/// around a name do not count. Only the rows the entry line knows are asked — the live ones;
/// an archived row is out of the vocabulary and out of sight, and «Добавить» with its name
/// brings it back rather than refusing.
enum ReferenceNames {
  static func folded(_ name: String) -> String {
    ReferenceRepository.nameKey(name)
  }

  static func spellings(_ person: Person) -> [String] { [person.name] + person.aliases }
  static func spellings(_ place: Place) -> [String] { [place.name] + place.aliases }
  static func spellings(_ method: PaymentMethod) -> [String] { [method.name] + method.aliases }

  /// Whether `name` is already one of the spellings of a row; each row is its name and aliases.
  static func isTaken(_ name: String, among rows: [[String]]) -> Bool {
    let wanted = folded(name)
    guard !wanted.isEmpty else { return false }
    return rows.contains { spellings in spellings.contains { folded($0) == wanted } }
  }
}
