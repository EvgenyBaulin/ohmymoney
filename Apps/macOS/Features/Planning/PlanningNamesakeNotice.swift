import AppCore
import AppDatabase
import SwiftUI

/// Advice beside the name field. Saving stays available; each action needs its own click.
/// Record identities, rather than the folded name, scope a remembered dismissal.
struct PlanningNamesakeNotice: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let kind: NamesakeKind
  let id: UUID
  @Binding var name: String
  var otherNames: Binding<[String]>? = nil
  var accountId: UUID? = nil
  var didRestore: ((NamesakeRecord) -> Void)? = nil
  var drafts: [NamesakeRecord] = []
  var renameDraft: ((UUID, String) -> Bool)? = nil
  /// Called after a rename or a restore landed, so the screen reads its own lists again.
  var onChange: (() -> Void)? = nil
  /// Narrows the stored records that count as namesakes (a category only clashes with one of
  /// its kind beside the same parent).
  var scope: ((NamesakeRecord) -> Bool)? = nil
  /// A form closes over a restored record; the add row of a dictionary stays where it is.
  var dismissesOnRestore = true
  @State private var records: [NamesakeRecord] = []
  @State private var financialRecords: [FinancialNamesakeRecord] = []
  @State private var hidden = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(proposals) { proposal in
        PlanningNamesakeRow(
          proposal: proposal, name: nameBinding(for: proposal),
          rename: { rename(proposal.existing, to: $0, spelling: proposal.existingSpelling) },
          restore: { restore(proposal.existing) },
          hide: { hide(proposal.id) })
      }
    }
    .onAppear { reload() }
    .onChange(of: store.writeRevision) { reload() }
  }

  private var isFinancial: Bool { [.account, .card, .bank].contains(kind) }

  private var proposals: [NamesakeProposal] {
    let own = NamesakeRecord(kind: kind, id: id, name: name)
    guard isFinancial else {
      return Namesakes.proposals(for: own, among: allRecords, hidden: hidden)
    }
    let visibility = environment.shield.covering
    let visible = financialRecords.filter {
      if $0.record.kind == .account { return !visibility.isHidden($0.record.id) }
      if let account = $0.accountId { return !visibility.isHidden(account) }
      return true
    }
    return Namesakes.financialProposals(
      for: own, aliases: otherNames?.wrappedValue ?? [],
      accountId: accountId, among: visible, hidden: hidden)
  }

  private func nameBinding(for proposal: NamesakeProposal) -> Binding<String> {
    guard let spelling = proposal.newSpelling, let otherNames else { return $name }
    return Binding(
      get: { spelling },
      set: { renamed in
        var aliases = otherNames.wrappedValue
        guard let index = aliases.firstIndex(of: spelling) else { return }
        aliases[index] = renamed
        otherNames.wrappedValue = aliases
      })
  }

  private var allRecords: [NamesakeRecord] {
    let draftIds = Set(drafts.map(\.id))
    // Dictionary names are never hidden by a covered account.
    if kind != .expectedIncome, kind != .scheduledPayment {
      return records.filter { !draftIds.contains($0.id) && (scope?($0) ?? true) } + drafts
    }
    // Stored names wait until the presentation knows which accounts are covered.
    guard let snapshot = compute.snapshot else { return drafts }
    let hiding = HiddenPlans(snapshot: snapshot)
    return Self.listed(records.filter { !draftIds.contains($0.id) } + drafts, hiding: hiding)
  }

  static func listed(_ records: [NamesakeRecord], hiding: HiddenPlans) -> [NamesakeRecord] {
    records.filter {
      switch $0.kind {
      case .expectedIncome: !hiding.hides(expected: $0.id)
      case .scheduledPayment: !hiding.hides(scheduled: $0.id)
      default: true
      }
    }
  }

  private func reload() {
    guard let book = try? environment.planning?.book() else { return }
    let entries =
      (try? environment.transactions?.entries(from: .distantPast, to: .distantFuture))
      ?? []
    if isFinancial {
      let accounts = (try? environment.references?.paymentMethods(includeArchived: true)) ?? []
      let cards =
        environment.stack.map {
          (try? CardRepository(writer: $0.writer).cards(includeArchived: true)) ?? []
        } ?? []
      let banks = (try? environment.references?.banks(includeArchived: true)) ?? []
      financialRecords = Namesakes.financialRecords(
        accounts: accounts, cards: cards, banks: banks,
        entries: entries, transfers: (try? environment.accounts?.transfers()) ?? [],
        planning: book, calendar: environment.calendar)
    }
    switch kind {
    case .expectedIncome:
      records = Namesakes.expected(
        book.expected, links: book.expectedLinks, entries: entries,
        calendar: environment.calendar)
    case .scheduledPayment:
      let matches = compute.wholeSnapshot?.planning.matches
      let matched = Dictionary(
        uniqueKeysWithValues: book.scheduled.map {
          ($0.id, Set(matches?.matchedDues(of: $0.id).values.map { $0 } ?? []))
        })
      records = Namesakes.scheduled(
        book.scheduled, entries: entries,
        calendar: environment.calendar, matchedOperations: matched)
    default:
      records = Self.dictionaryRecords(
        kind, references: environment.references, entries: entries,
        calendar: environment.calendar)
    }
    hidden = (try? environment.settings?.string(Namesakes.hiddenPairsKey)) ?? ""
  }

  /// The dictionaries' names, archived rows too, each with the history its operations tell.
  static func dictionaryRecords(
    _ kind: NamesakeKind, references: ReferenceRepository?, entries: [TransactionEntry],
    calendar: CalendarContext
  ) -> [NamesakeRecord] {
    guard let references else { return [] }
    switch kind {
    case .goal:
      return Namesakes.goals(
        (try? references.goals(includeArchived: true)) ?? [], entries: entries,
        calendar: calendar)
    case .event: return Namesakes.events((try? references.events(includeArchived: true)) ?? [])
    case .person:
      return Namesakes.people(
        (try? references.people(includeArchived: true)) ?? [], entries: entries,
        calendar: calendar)
    case .place:
      return Namesakes.places(
        (try? references.places(includeArchived: true)) ?? [], entries: entries,
        calendar: calendar)
    case .category:
      return Namesakes.categories(
        (try? references.categories(includeArchived: true)) ?? [], entries: entries,
        calendar: calendar)
    default: return []
    }
  }

  private func rename(_ record: NamesakeRecord, to name: String, spelling: String?) -> Bool {
    if drafts.contains(where: { $0.id == record.id }), let renameDraft {
      return renameDraft(record.id, PlanningActions.trimmed(name))
    }
    guard let dependencies, let book = try? environment.planning?.book(),
      PlanningActions(dependencies).renameNamesake(record, to: name, spelling: spelling, in: book)
    else { return false }
    onChange?()
    reload()
    return true
  }

  private func restore(_ record: NamesakeRecord) -> Bool {
    guard let dependencies, let book = try? environment.planning?.book(),
      PlanningActions(dependencies).restoreNamesake(record, in: book)
    else { return false }
    onChange?()
    if let didRestore { didRestore(record) } else if dismissesOnRestore { dismiss() }
    reload()
    return true
  }

  private func hide(_ pair: String) -> Bool {
    guard let dependencies,
      PlanningActions(dependencies).hideNamesake(pair, stored: hidden)
    else { return false }
    hidden = Namesakes.hiding(pair, in: hidden)
    return true
  }
}

private struct PlanningNamesakeRow: View {
  @Dependency(\.environment) private var environment
  let proposal: NamesakeProposal
  @Binding var name: String
  let rename: (String) -> Bool
  let restore: () -> Bool
  let hide: () -> Bool
  @State private var renaming = false
  @State private var renamesExisting = false
  @State private var proposedName = ""
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(
          verbatim: environment.format(
            proposal.existing.archived ? "namesake.archived" : "namesake.live",
            table: "Planning", proposal.existing.name))
      } icon: {
        Image(systemName: proposal.existing.archived ? "archivebox" : "exclamationmark.circle")
      }
      Text(verbatim: t(isFinancial ? "namesake.financial.unique" : "namesake.canSave"))
      if let alias = proposal.existingSpelling {
        Text(verbatim: environment.format("namesake.financial.alias", table: "Planning", alias))
      }
      if proposal.existing.archived, proposal.existing.period == nil {
        Text(verbatim: t("namesake.noHistory"))
      }
      if proposal.choices.contains(.renameNew) {
        Button(t(newRenameKey)) { beginRename(existing: false) }
      }
      Button(t(existingRenameKey)) {
        beginRename(existing: true)
      }
      if let suggested = proposal.archivedName(locale: environment.language.locale) {
        Text(verbatim: environment.format("namesake.suggested", table: "Planning", suggested))
      }
      if proposal.existing.archived {
        Button(
          t(proposal.restoresAccount ? "namesake.financial.restoreCardAccount" : "namesake.restore")
        ) {
          failed = !restore()
        }
      }
      Button(t("namesake.hidePair")) { failed = !hide() }
      if failed {
        Text(verbatim: t(isFinancial ? "namesake.financial.notSaved" : "form.notSaved"))
          .foregroundStyle(.red)
      }
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("namesake.notice")
    .modifier(
      NamesakeRenameAlert(
        presented: $renaming, proposedName: $proposedName,
        title: t(renamesExisting ? existingRenameKey : newRenameKey),
        field: t("form.name"), save: t("namesake.rename"),
        cancel: environment.language("action.cancel"),
        apply: {
          if renamesExisting {
            failed = !rename(proposedName)
          } else {
            name = PlanningActions.trimmed(proposedName)
            failed = false
          }
        }))
  }

  private var newRenameKey: String {
    proposal.newSpelling == nil ? "namesake.renameNew" : "namesake.financial.renameNewAlias"
  }

  private var existingRenameKey: String {
    if proposal.existingSpelling != nil { return "namesake.financial.renameArchivedAlias" }
    return proposal.existing.archived ? "namesake.renameArchived" : "namesake.renameExisting"
  }

  private var isFinancial: Bool {
    [.account, .card, .bank].contains(proposal.existing.kind)
  }

  private func beginRename(existing: Bool) {
    renamesExisting = existing
    proposedName =
      existing
      ? proposal.archivedName(locale: environment.language.locale) ?? proposal.existingSpelling
        ?? proposal.existing.name : name
    renaming = true
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

private struct NamesakeRenameAlert: ViewModifier {
  @Binding var presented: Bool
  @Binding var proposedName: String
  let title: String
  let field: String
  let save: String
  let cancel: String
  let apply: () -> Void

  func body(content: Content) -> some View {
    content.alert(title, isPresented: $presented) {
      TextField(field, text: $proposedName)
      Button(save, action: apply)
        .disabled(PlanningActions.trimmed(proposedName).isEmpty)
      Button(cancel, role: .cancel) {}
    }
  }
}
