import AppCore
import AppDatabase
import SwiftUI

/// Categories, their subcategories and their quality, as one flat list: a category in bold, its
/// subcategories indented under it, every row alike — no heading sticks to the top of the list.
///
/// System categories (Goals, Loans, Unknown, Surcharges) — and everything under them, a goal's
/// subcategory and a debt's — can be renamed, but not archived or deleted: the app finds them
/// by their role and their place in the tree, never by name. A goal contribution is always
/// good: the quality picker of Goals and of every goal's subcategory is disabled rather than
/// silently ignored. Among the income categories the owner also says which one is cashback.
///
/// A new quality counts for the operations to come at once; whether the past follows is a
/// question, asked when there is something to change.
///
/// Every way out of a category lives in one menu on its row: delete, archive, and — the one
/// that was missing — bring back from the archive. Until 21.09 archiving was a small button
/// that made the row disappear for good, because nothing in the app ever listed an archived
/// category again.
///
/// Every row that can take a limit — an expense category in use, not a system one — has a
/// field for its monthly limit: an amount sets it, an empty field removes it, zero is refused,
/// each commit one step of ⌘Z; ↻ marks a limit whose leftover carries over.
struct CategoriesSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  /// Handed to the question of a deletion: a sheet is laid out by a host of its own.
  @Environment(\.dependencies) private var dependencies
  @State private var categories: [CoreKit.Category] = []
  /// The operations a new quality would re-rate, waiting for the owner's answer.
  @State private var pastQuality: PastQualityQuestion?
  @State private var counting: Task<Void, Never>?
  @State private var newName = ""
  @State private var newParent: UUID?
  @State private var kind: CategoryKind = .expense
  @State private var cashbackId: UUID?
  /// The archive is a place, not a hole: the list shows it when asked.
  @State private var showsArchived = false
  /// The category the owner asked to delete, and what points at it.
  @State private var deleting: CategoryDeletion?
  /// Where the operations of a used category go when it is deleted.
  @State private var moveTo: UUID?
  /// Said out loud when a write was refused, instead of the row simply not moving.
  @State private var refusalKey: String?
  /// The row whose name is being typed; its name is saved when the focus leaves it.
  @FocusState private var editingName: UUID?
  /// A write the database itself refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false
  /// The limits as the database has them, read with the categories and after every write.
  @State private var budgets: [Budget] = []
  /// «Сверка» and its income twin: no limit field on them or under them.
  @State private var limitless: Set<UUID> = []
  /// Why the last amount typed into a limit's field was not written, and in which row.
  @State private var limitRefusal: LimitRefusal?
  /// Self-employment as the database has it: the tax of an income category is offered only
  /// while it is on, and the category the tax is paid in takes no limit.
  @State private var selfEmployment = SelfEmploymentSettings.standard
  /// The income category whose «Другая…» rate of tax is being typed.
  @State private var otherTax: CoreKit.Category?

  /// `asking` opens the tab with the question of a deletion already on screen: how a test
  /// lays out the sheet without a click on a row's menu.
  init(asking deletion: CategoryDeletion? = nil) {
    _deleting = State(initialValue: deletion)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker(selection: $kind) {
          Text(verbatim: environment.language("kind.expense")).tag(CategoryKind.expense)
          Text(verbatim: environment.language("kind.income")).tag(CategoryKind.income)
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Toggle(isOn: $showsArchived) {
          Text(verbatim: environment.language("categories.showArchived", table: "Settings"))
        }
        .toggleStyle(.checkbox)
        .fixedSize()
        .onChange(of: showsArchived) { _, _ in reload() }
      }

      // Rows, not sections: the header of a section stuck to the top of the list while its
      // subcategories scrolled under it, with a background of its own.
      List {
        ForEach(Self.rows(roots: roots, children: children(of:), orphans: orphans)) { line in
          switch line {
          case .category(let category, let isChild):
            row(category, isChild: isChild)
          case .orphansCaption:
            // A live subcategory whose parent is in the archive has no row to hang on while
            // the archive is hidden — and it is still the category of its own past operations.
            // It is listed after this line rather than disappearing from the only screen that
            // can rename, archive or delete it.
            Text(verbatim: environment.language("categories.orphans", table: "Settings"))
              .appFont(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 220)

      HStack {
        TextField(text: $newName) {
          Text(verbatim: environment.language("references.name", table: "Settings"))
        }
        Picker(selection: $newParent) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(liveRoots, id: \.id) { parent in
            Text(verbatim: parent.name).tag(UUID?.some(parent.id))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        Button(environment.language("references.add", table: "Settings"), action: add)
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
      }

      if let refusalKey {
        Text(verbatim: environment.language(refusalKey, table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.red)
          .onTapGesture { self.refusalKey = nil }
      }

      if kind == .expense {
        if let limitRefusal {
          Text(verbatim: limitRefusal.text)
            .appFont(.callout)
            .foregroundStyle(.red)
            .onTapGesture { self.limitRefusal = nil }
            .accessibilityIdentifier("categories.limit.refusal")
        }
        Text(verbatim: environment.language("categories.limit.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if kind == .income {
        cashbackPicker
      }
    }
    .padding()
    .onAppear(perform: reload)
    .onChange(of: editingName) { left, _ in
      if let left { commitName(of: left) }
    }
    .onDisappear {
      if let editingName { commitName(of: editingName) }
    }
    .refusedWriteAlert($refused, environment)
    .onChange(of: kind) { _, _ in
      // A root of one kind is never the parent of a category of the other.
      newParent = nil
      limitRefusal = nil
      reload()
    }
    // A limit set or taken back elsewhere — in Planning, by ⌘Z — shows in its row at once;
    // so does self-employment switched on or off.
    .onChange(of: compute.generation) {
      selfEmployment = SelfEmploymentSettingsForm.read(environment)
      reloadLimits()
    }
    // «Налог → Другая…»: a rate typed by hand, on a sheet over the settings.
    .sheet(item: $otherTax) { category in
      OtherTaxSheet(category: category) { rate in
        setTax(of: category, to: .other(rate))
      }
      .handingOver(dependencies)
    }
    // A sheet, not a `confirmationDialog`: when the operations of a category have to move,
    // the owner has to choose where — and a dialog holds buttons, not a picker. On the root
    // of the tab, never on a row: the rows are rebuilt by every reload.
    .sheet(item: $deleting) { question in
      CategoryDeletionSheet(
        question: question, moveTo: $moveTo,
        options: moveOptions(excluding: question),
        title: deleteTitle, message: deleteMessage(question),
        archive: {
          setArchived(question.category, true)
          deleting = nil
        },
        delete: { delete(question) },
        cancel: { deleting = nil }
      )
      .handingOver(dependencies)
    }
    .confirmationDialog(
      CategoryQualityText.title(environment.language), isPresented: isAsking,
      titleVisibility: .visible, presenting: pastQuality
    ) { question in
      Button(CategoryQualityText.apply(environment.language)) {
        store.apply(question.change, to: question.ids)
      }
      .disabled(store.isWritingInBackground)
      Button(CategoryQualityText.keep(environment.language), role: .cancel) {}
    } message: { question in
      Text(verbatim: CategoryQualityText.message(question.ids.count, environment.language))
    }
  }

  /// What the owner asked to delete and what points at it.
  struct CategoryDeletion: Identifiable {
    let category: CoreKit.Category
    /// Subcategories that would go with it.
    let children: Int
    /// Operations in the book that point at it or at one of its children.
    let live: Int
    /// The same, among operations already in the bin. They still hold their parts, and the
    /// schema refuses to drop a category anything points at — so these block a deletion and
    /// nothing in the app can move them.
    let binned: Int

    var id: UUID { category.id }
    var blocked: Bool { binned > 0 }
  }

  private var deleteTitle: String {
    environment.language("categories.delete.title", table: "Settings")
  }

  private func deleteMessage(_ question: CategoryDeletion) -> String {
    CategoryDeletionText.message(question, environment.language)
  }

  /// Every live category of the same kind except the one going and its children, named
  /// «Родитель › Ребёнок» so two subcategories called «Прочее» are told apart.
  private func moveOptions(excluding deletion: CategoryDeletion) -> [(id: UUID, name: String)] {
    let tree = wholeTree()
    let inside = Set([deletion.category.id] + tree.children(of: deletion.category.id).map(\.id))
    return
      categories
      .filter { $0.kind == kind && !$0.archived && !inside.contains($0.id) }
      // Never a system category or anything under one: the rule that moves operations refuses
      // them (`BulkEditRule.refusal`), so offering one would move nothing, and the deletion
      // would then fail for a reason the owner never saw.
      .filter { tree.systemRole(of: $0.id) == nil }
      .map { (id: $0.id, name: name(of: $0, tree: tree)) }
  }

  private func name(of category: CoreKit.Category, tree: CategoryTree) -> String {
    guard let parent = category.parentId, let root = tree.category(parent) else {
      return category.name
    }
    return "\(root.name) › \(category.name)"
  }

  private var isAsking: Binding<Bool> {
    Binding(
      get: { pastQuality != nil },
      set: { isShown in
        if !isShown { pastQuality = nil }
      })
  }

  /// One line of the list: a category, flush left or indented under its parent, or the caption
  /// before the subcategories whose parent is in the archive.
  enum Line: Identifiable, Equatable {
    case category(CoreKit.Category, isChild: Bool)
    case orphansCaption

    var id: String {
      switch self {
      case .category(let category, _): category.id.uuidString
      case .orphansCaption: "orphans"
      }
    }
  }

  /// The list in the order it is read: each category followed by its subcategories, then — when
  /// there are any — the caption and the subcategories whose parent is not listed.
  static func rows(
    roots: [CoreKit.Category], children: (CoreKit.Category) -> [CoreKit.Category],
    orphans: [CoreKit.Category]
  ) -> [Line] {
    var lines: [Line] = []
    for parent in roots {
      lines.append(.category(parent, isChild: false))
      lines += children(parent).map { .category($0, isChild: true) }
    }
    if !orphans.isEmpty {
      lines.append(.orphansCaption)
      lines += orphans.map { .category($0, isChild: true) }
    }
    return lines
  }

  private func row(_ category: CoreKit.Category, isChild: Bool) -> some View {
    // Read once for the row: both the caption of a system category and the quality picker ask.
    let tree = wholeTree()
    let isSystem = tree.systemRole(of: category.id) != nil
    return HStack {
      TextField(text: nameBinding(for: category)) { EmptyView() }
        .labelsHidden()
        .textFieldStyle(.plain)
        .fontWeight(isChild ? .regular : .semibold)
        .focused($editingName, equals: category.id)
        .onSubmit { commitName(of: category.id) }
        .padding(.leading, isChild ? 18 : 0)
        .frame(maxWidth: 240, alignment: .leading)
      // A system category can be renamed, but not archived or deleted — and neither can a
      // subcategory of one: the role is handed down by the tree, and a goal's subcategory taken
      // away would be made again by the next contribution. Said in a word, with the reason on
      // hover, rather than by a bare lock.
      if isSystem {
        Text(verbatim: environment.language("categories.system", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .help(environment.language("categories.system.help", table: "Settings"))
          .accessibilityIdentifier("categories.row.system")
      } else {
        if category.archived {
          Text(verbatim: environment.language("categories.archived", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
        if kind == .expense, tree.isEssential(category.id) {
          Label {
            Text(verbatim: environment.language("categories.essential.mark", table: "Settings"))
          } icon: {
            Image(systemName: CushionText.symbol)
          }
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("categories.row.essential")
        }
        if kind == .income, selfEmployment.enabled,
          let mark = CategoryTax.mark(category.id, tree: tree, environment)
        {
          // The tax, in words beside its symbol: never told by colour.
          Label {
            Text(verbatim: mark)
          } icon: {
            Image(systemName: "percent")
          }
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("categories.row.tax")
        }
        Menu {
          if kind == .income, selfEmployment.enabled {
            Picker(selection: taxBinding(for: category, tree: tree)) {
              ForEach(
                taxChoices(for: category), id: \.self
              ) { choice in
                Text(verbatim: CategoryTax.title(choice, environment)).tag(choice)
              }
            } label: {
              Text(verbatim: environment.language("categories.tax", table: "Settings"))
            }
            .disabled(CategoryTax.isFixed(category, in: tree))
            Button(environment.language("categories.tax.other", table: "Settings")) {
              otherTax = category
            }
            .disabled(CategoryTax.isFixed(category, in: tree))
            Divider()
          }
          if kind == .expense {
            Picker(selection: essentialBinding(for: category, tree: tree)) {
              ForEach(Self.essentialChoices(for: category), id: \.self) { choice in
                Text(
                  verbatim: environment.language(
                    "categories.essential.\(choice.rawValue)", table: "Settings")
                )
                .tag(choice)
              }
            } label: {
              Text(verbatim: environment.language("categories.essential", table: "Settings"))
            }
            .disabled(Self.essentialIsFixed(category, in: tree))
            Picker(selection: basketBinding(for: category, tree: tree)) {
              ForEach(BasketChoice.allCases, id: \.self) { choice in
                Text(verbatim: BasketChoice.name(choice, environment)).tag(choice)
              }
            } label: {
              Text(verbatim: IncomeSavingsText.t("income.basket.menu", environment))
            }
            .disabled(BasketChoice.isFixed(category, in: tree))
            Divider()
          }
          Button(environment.language("references.delete", table: "Settings")) {
            askToDelete(category)
          }
          if category.archived {
            Button(environment.language("categories.unarchive", table: "Settings")) {
              setArchived(category, false)
            }
          } else {
            Button(environment.language("references.archive", table: "Settings")) {
              setArchived(category, true)
            }
          }
        } label: {
          // Named by its category, like the «…» of every row of Справочники: the bare symbol
          // was read as «More» on every row alike.
          Image(systemName: "ellipsis.circle")
            .accessibilityLabel(
              Text(
                verbatim: environment.format(
                  "references.rowMenu", table: "Settings", category.name)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("categories.row.menu")
      }
      Spacer(minLength: 8)
      if kind == .expense {
        if LimitRules.offersLimit(
          on: category.id, tree: tree, limitless: limitless,
          taxCategoryId: selfEmployment.taxCategoryId)
        {
          CategoryLimitField(
            stored: LimitRules.categoryLimit(of: category.id, in: budgets),
            commit: { commitLimit($0, for: category.id) },
            cancel: {
              if limitRefusal?.categoryId == category.id { limitRefusal = nil }
            })
        } else {
          // Keeps the pickers of quality in one column.
          Color.clear.frame(width: CategoryLimitField.width, height: 1)
        }
        Picker(selection: qualityBinding(for: category)) {
          Text(verbatim: "—").tag(Quality?.none)
          ForEach(Quality.allCases, id: \.self) { quality in
            Text(verbatim: environment.language(Palette.qualityKey(quality)))
              .tag(Quality?.some(quality))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .frame(width: 150)
        .disabled(Self.qualityIsFixed(category, in: tree))
      }
    }
  }

  /// Whether the quality of a category is not the owner's to choose: Goals and everything
  /// under it, because a contribution is always good whatever its subcategory says
  /// (`QualityResolver`). Loans, a debt's subcategory and «Не помню» keep a quality of their
  /// own — there it is only the default («оценка по умолчанию neutral»).
  static func qualityIsFixed(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    tree.isGoalCategory(category.id)
  }

  /// Whether a category can be essential spending: only an expense category of the owner's —
  /// a system one (and everything under it) never is.
  static func essentialIsFixed(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    category.kind != .expense || tree.systemRole(of: category.id) != nil
  }

  /// «Как у категории» only where there is a category above to follow.
  static func essentialChoices(for category: CoreKit.Category) -> [EssentialChoice] {
    category.parentId == nil ? [.yes, .no] : EssentialChoice.allCases
  }

  /// The new mark of a category as one step of ⌘Z; `nil` when it is what is stored already, or
  /// when the category cannot be essential.
  static func essentialChange(
    _ category: CoreKit.Category, to choice: EssentialChoice, tree: CategoryTree, at now: Date
  ) -> PlanningChange? {
    guard !essentialIsFixed(category, in: tree) else { return nil }
    let value = choice.value
    guard value != category.essential else { return nil }
    var updated = category
    updated.essential = value
    return PlanningChange(upsert: PlanningRows(categories: [updated]), at: now)
  }

  /// The mark a menu shows: nothing on a category at the top is «нет».
  private func essentialBinding(
    for category: CoreKit.Category, tree: CategoryTree
  ) -> Binding<EssentialChoice> {
    Binding(
      get: { EssentialChoice(category.essential, isTop: category.parentId == nil) },
      set: { choice in
        guard
          let change = Self.essentialChange(
            category, to: choice, tree: tree, at: environment.now())
        else { return }
        guard store.apply(change) else {
          refused = true
          return
        }
        AppLog.info(
          "cushion.essential.set", .db, "a category became or stopped being essential",
          [LogPair("categories", .count(1))])
        reload()
      })
  }

  /// The basket of a category in the budget proportions (50 / 30 / 20): «Как у родителя»
  /// until the owner moves it.
  private func basketBinding(
    for category: CoreKit.Category, tree: CategoryTree
  ) -> Binding<BasketChoice> {
    Binding(
      get: { BasketChoice(category.basket) },
      set: { choice in
        guard !BasketChoice.isFixed(category, in: tree), choice != BasketChoice(category.basket)
        else { return }
        guard store.setBasket(choice.basket, ofCategory: category.id) else {
          refused = true
          return
        }
        AppLog.info(
          "income.basket.set", .db, "a category was moved to another basket",
          [LogPair("categories", .count(1))])
        reload()
      })
  }

  /// The choices of the tax menu of a row, with a rate typed by hand kept as a choice of its
  /// own while it is the one stored.
  private func taxChoices(for category: CoreKit.Category) -> [TaxChoice] {
    var choices = CategoryTax.choices(for: category, reference: selfEmployment.reference)
    let stored = CategoryTax.choice(of: category)
    if !choices.contains(stored) { choices.append(stored) }
    return choices
  }

  private func taxBinding(
    for category: CoreKit.Category, tree: CategoryTree
  ) -> Binding<TaxChoice> {
    Binding(
      get: { CategoryTax.choice(of: category) },
      set: { choice in _ = setTax(of: category, to: choice) })
  }

  /// The tax of a category as one step of ⌘Z. True when it is written or was already so.
  @discardableResult
  private func setTax(of category: CoreKit.Category, to choice: TaxChoice) -> Bool {
    let tree = wholeTree()
    let current = tree.category(category.id) ?? category
    guard let change = CategoryTax.change(current, to: choice, tree: tree, at: environment.now())
    else { return true }
    guard store.apply(change) else {
      refused = true
      return false
    }
    AppLog.info(
      "categories.tax.set", .db, "the tax of an income category changed",
      [LogPair("categories", .count(1))])
    reload()
    return true
  }

  /// The income category whose money Analytics counts as cashback, subcategories included.
  private var cashbackPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(selection: cashbackBinding) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(liveRoots, id: \.id) { parent in
          Text(verbatim: parent.name).tag(UUID?.some(parent.id))
          ForEach(children(of: parent).filter { !$0.archived }, id: \.id) { child in
            Text(verbatim: "\(parent.name) › \(child.name)").tag(UUID?.some(child.id))
          }
        }
      } label: {
        Text(verbatim: environment.language("categories.cashback", table: "Settings"))
      }
      Text(verbatim: environment.language("categories.cashbackHint", table: "Settings"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
      // What the category above receives is set here; what to expect, by the cards' rules.
      Text(verbatim: environment.language(Self.cashbackRulesHintKey, table: "Settings"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// «—» is kept as an empty value, so the choice survives the next launch instead of being
  /// taken for a setting never made.
  private var cashbackBinding: Binding<UUID?> {
    Binding(
      get: { cashbackId },
      set: { newValue in
        guard
          environment.attempt(
            "settings.cashback", on: environment.settings,
            { try $0.set(AnalyticsSettings.cashbackCategoryKey, to: newValue?.uuidString ?? "") })
        else {
          refused = true
          return
        }
        cashbackId = newValue
        environment.scheduleBackup()
      })
  }

  private var roots: [CoreKit.Category] {
    categories.filter { $0.kind == kind && $0.parentId == nil }
  }

  /// What a picker may offer. `roots` carries archived rows once the toggle is on, and a new
  /// category filed under an archived parent is refused by every rule that reads the tree.
  /// Deliberately derived from `roots` and never from `orphans`: a subcategory must not
  /// become an offer to be somebody's parent.
  private var liveRoots: [CoreKit.Category] {
    roots.filter { !$0.archived }
  }

  /// Subcategories of this kind whose parent is not on screen.
  private var orphans: [CoreKit.Category] {
    let shown = Set(roots.map(\.id))
    return categories.filter { $0.kind == kind && $0.parentId.map { !shown.contains($0) } == true }
  }

  private func children(of parent: CoreKit.Category) -> [CoreKit.Category] {
    categories.filter { $0.parentId == parent.id }
  }

  /// The new quality is saved at once and counts for the operations to come. Whether the
  /// past follows is asked next, once the operations it would change have been counted.
  private func qualityBinding(for category: CoreKit.Category) -> Binding<Quality?> {
    Binding(
      get: { category.quality },
      set: { newValue in
        guard newValue != category.quality else { return }
        var updated = category
        updated.quality = newValue
        guard
          environment.attempt(
            "categories.save", on: environment.references, { try $0.save(updated) })
        else {
          refused = true
          return
        }
        reload()
        environment.scheduleBackup()
        askAboutThePast(CategoryQualityChange(categoryId: category.id))
      })
  }

  /// Counts, off the main thread and over the pipeline's ledger, the operations the new
  /// quality would re-rate, and asks about them — nothing is asked when there are none.
  /// The categories are read as they are now, the new quality with them: the ledger reads
  /// them again only a moment later. A newer change replaces a count still running.
  private func askAboutThePast(_ change: CategoryQualityChange) {
    counting?.cancel()
    guard let ledger = compute.snapshot?.ledger else { return }
    let tree = CategoryTree(store.categories())
    counting = Task {
      guard
        let ids = try? await compute.compute({ change.affected(ledger.entries, tree: tree) }),
        !Task.isCancelled, !ids.isEmpty
      else { return }
      pastQuality = PastQualityQuestion(change: change, ids: ids)
    }
  }

  /// What the owner types stays in the local copy, so typing does not fight with the
  /// database; it is saved once — on Return, when the field loses focus, when the list reloads
  /// or the tab goes away (`commitName`). Until 24.09 every keystroke was a write, a backup
  /// scheduled and a run of the pipeline.
  private func nameBinding(for category: CoreKit.Category) -> Binding<String> {
    Binding(
      get: {
        categories.first { $0.id == category.id }?.name ?? category.name
      },
      set: { newValue in
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index].name = newValue
      })
  }

  /// Saves the name typed into the row of `id`, trimmed. A name emptied, or typed back to what
  /// is stored, writes nothing, and the row shows the stored name again. A name the database
  /// refused stays typed in the row, and the alert says it was not saved
  /// (`AppEnvironment.attempt`).
  private func commitName(of id: UUID) {
    guard let index = categories.firstIndex(where: { $0.id == id }),
      let all = try? environment.references?.categories(includeArchived: true),
      let stored = all.first(where: { $0.id == id })
    else { return }
    guard let renamed = Self.renamed(stored, to: categories[index].name) else {
      categories[index].name = stored.name
      return
    }
    guard !Self.nameIsTaken(renamed.name, by: stored, among: all) else {
      categories[index].name = stored.name
      refusalKey = "categories.rename.taken"
      return
    }
    guard
      environment.attempt("categories.save", on: environment.references, { try $0.save(renamed) })
    else {
      refused = true
      return
    }
    categories[index].name = renamed.name
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }

  /// The category to save for a name typed into its row, or nothing to save.
  static func renamed(_ stored: CoreKit.Category, to typed: String) -> CoreKit.Category? {
    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != stored.name else { return nil }
    var renamed = stored
    renamed.name = name
    return renamed
  }

  /// Whether `name` would make `category` one of two alike: the pickers and the entry line know
  /// a category by its name, and two of one kind under one parent — or a subcategory named as a
  /// category — could not be told apart there. Only the live ones are asked, as the pickers and
  /// the entry line know only those, and as the other books of the settings ask: a name refused
  /// for a row nobody can see is a refusal nobody can read.
  /// Case, «ё» and spaces make no difference.
  static func nameIsTaken(
    _ name: String, by category: CoreKit.Category, among all: [CoreKit.Category]
  ) -> Bool {
    let folded = fold(name)
    return all.contains { other in
      other.id != category.id && !other.archived && other.kind == category.kind
        && (other.parentId == category.parentId || other.parentId == nil
          || category.parentId == nil)
        && fold(other.name) == folded
    }
  }

  /// A name as the owner reads it: lower case, «ё» as «е», one space between words.
  private static func fold(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: "ё", with: "е")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private func setArchived(_ category: CoreKit.Category, _ archived: Bool) {
    var updated = category
    updated.archived = archived
    if !environment.attempt(
      "categories.archive", on: environment.references, { try $0.save(updated) })
    {
      refused = true
    }
    // A category brought back has to be visible even with the archive hidden.
    reload()
    environment.scheduleBackup()
  }

  /// Categories the app owns: the four system roots and everything under them. `isSystem`
  /// alone is not enough — a goal's subcategory and a debt's carry no role of their own and
  /// take it from their parent through the tree.
  private func isOwnedByTheApp(_ category: CoreKit.Category) -> Bool {
    wholeTree().systemRole(of: category.id) != nil
  }

  /// Every category there is, archived included. The displayed list follows the toggle, but a
  /// decision — what is system, what hangs under what, what would go with what — must never
  /// be made on a part of the book: an archived subcategory invisible to a deletion is a
  /// deletion the schema then refuses.
  private func wholeTree() -> CategoryTree {
    CategoryTree((try? environment.references?.categories(includeArchived: true)) ?? categories)
  }

  /// What points at a category, counted before anything is written: whether it can simply go,
  /// or whether its operations have to move first.
  private func askToDelete(_ category: CoreKit.Category) {
    guard !isOwnedByTheApp(category) else { return }
    // Two levels deep is all this tree ever is (категория и подкатегория), and it is read
    // whole: an archived subcategory holds the same references as a live one.
    let inside = [category.id] + wholeTree().children(of: category.id).map(\.id)
    // Without the data nothing can be counted, and a delete offered on a guess would fail at
    // the schema and look like a bug. The pipeline fills this a moment after the app starts.
    guard let all = compute.snapshot?.dataset.entries else {
      refusalKey = "categories.delete.notReady"
      return
    }
    // A write of many is already on its way; counting now would count the book as it was.
    guard !store.isWritingInBackground else {
      refusalKey = "categories.delete.busy"
      return
    }
    let ids = Set(inside)
    // The pipeline's data is live-only by construction — it is read with `deleted_at IS NULL`
    // — so what sits in the bin has to be asked of the database itself. Those parts still
    // point at the category, and nothing in the app can re-file them.
    let live = all.filter { $0.parts.contains { $0.categoryId.map(ids.contains) == true } }.count
    let binned = (try? environment.transactions?.binnedOperations(inCategories: inside)) ?? 0
    moveTo = nil
    deleting = CategoryDeletion(
      category: category, children: inside.count - 1, live: live, binned: binned)
  }

  /// Deletes the category, having moved what points at it when there was anything to move.
  /// Two writes when operations had to move, and the dialog says so: one ⌘Z takes back the
  /// deletion, a second one the move.
  private func delete(_ deletion: CategoryDeletion) {
    defer { deleting = nil }
    let inside = [deletion.category.id] + wholeTree().children(of: deletion.category.id).map(\.id)
    let outcome = Self.delete(
      inside, live: deletion.live, moveTo: moveTo,
      entries: compute.snapshot?.dataset.entries ?? [], store: store)
    refusalKey = outcome.refusalKey
    // A move that landed is on screen whatever became of the deletion after it.
    guard outcome.refusalKey == nil || outcome.moved else { return }
    reload()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }

  /// What became of deleting: the key of what the owner is told (nil when the category went),
  /// and whether its operations were moved first.
  struct DeletionOutcome: Equatable {
    var refusalKey: String?
    var moved: Bool
  }

  /// The writes of deleting the categories `inside` (the one chosen and its children): first
  /// the `live` operations filed under them move to `target`, then the categories go.
  static func delete(
    _ inside: [UUID], live: Int, moveTo target: UUID?, entries: [TransactionEntry],
    store: TransactionsStore
  ) -> DeletionOutcome {
    var moved = false
    if live > 0 {
      guard let target,
        moveOperations(of: Set(inside), to: target, entries: entries, store: store)
      else {
        return DeletionOutcome(refusalKey: "categories.delete.failed", moved: false)
      }
      moved = true
      // A move of more than a thousand operations is written off the main thread and answers
      // «yes» before it has landed. Deleting on top of that would race the write, so the
      // category waits: the move is real, and one ⌘Z takes it back.
      if store.isWritingInBackground {
        return DeletionOutcome(refusalKey: "categories.delete.moving", moved: true)
      }
    }
    var rows = PlanningRowIDs.empty
    // Children first: a parent still referenced by its own child cannot go.
    rows.categories = inside.reversed()
    guard store.apply(PlanningChange(delete: rows)) else {
      // Something points at the category that was not there when the operations were
      // counted — one filed since, or put in the bin. The move is written by then, a step of
      // ⌘Z of its own, and the owner is told so.
      return DeletionOutcome(
        refusalKey: moved ? "categories.delete.failedAfterMove" : "categories.delete.failed",
        moved: moved)
    }
    return DeletionOutcome(refusalKey: nil, moved: moved)
  }

  /// The first write of deleting a used category: the live operations filed under one of
  /// `inside` move to `target`. Returns whether there was something to move and it moved.
  ///
  /// Only their parts in `inside` move. Each part of a split has a category of its own,
  /// and the question promises to move what lies in the category going; until 24.09
  /// this was the list's bulk change of category, which reaches every part of a split.
  static func moveOperations(
    of inside: Set<UUID>, to target: UUID, entries: [TransactionEntry],
    store: TransactionsStore
  ) -> Bool {
    let moving =
      entries
      .filter { $0.transaction.deletedAt == nil }
      .filter { $0.parts.contains { $0.categoryId.map(inside.contains) == true } }
      .map(\.id)
    guard !moving.isEmpty else { return false }
    return store.apply(.refile(from: inside, to: target), to: moving)
  }

  private func reload() {
    // A name still being typed is saved first: the read below would put the stored one back.
    if let editingName { commitName(of: editingName) }
    categories = (try? environment.references?.categories(includeArchived: showsArchived)) ?? []
    selfEmployment = SelfEmploymentSettingsForm.read(environment)
    cashbackId = (try? environment.settings?.string(AnalyticsSettings.cashbackCategoryKey))
      .flatMap { $0 }.flatMap(UUID.init(uuidString:))
    reloadLimits()
  }

  private func reloadLimits() {
    budgets = LimitWrites.budgets(environment, compute.snapshot)
    // The category the tax of self-employment is paid in, and everything under it, takes no
    // limit: the tax is not spending to hold back.
    limitless = LimitWrites.limitless(environment, compute.snapshot)
      .union(selfEmployment.taxCategoryId.map { [$0] } ?? [])
  }

  /// Under the cashback category: how much cashback to expect is set by the cards' rules.
  static let cashbackRulesHintKey = "categories.cashbackRulesHint"

  /// Why the amount typed into a row was not written, and which row it was.
  struct LimitRefusal: Equatable {
    let categoryId: UUID
    let text: String
  }

  /// The amount typed into the limit field of a category's row, written as one step of ⌘Z
  /// (`commitLimit(_:for:budgets:tree:month:store:)`). Returns whether it was written — or
  /// said what is stored; false leaves the reason under the list, named after the row.
  private func commitLimit(_ text: String, for categoryId: UUID) -> Bool {
    let tree = wholeTree()
    let key = Self.commitLimit(
      text, for: categoryId, budgets: LimitWrites.budgets(environment, compute.snapshot),
      tree: tree, month: environment.today.monthKey, store: store,
      limitless: LimitWrites.limitless(environment, compute.snapshot))
    reloadLimits()
    limitRefusal = key.map {
      LimitRefusal(
        categoryId: categoryId,
        text: Self.limitRefusal($0, for: categoryId, tree: tree, environment))
    }
    return key == nil
  }

  /// The reason under the list with the row it is about, «Еда вне дома › Кофейни: Лимит
  /// должен быть больше нуля»: the list is long, and the field may have been left for another.
  static func limitRefusal(
    _ key: String, for categoryId: UUID, tree: CategoryTree, _ environment: AppEnvironment
  ) -> String {
    let reason = environment.language(key, table: "Planning")
    guard let name = PlanningText.categoryPath(categoryId, tree: tree) else { return reason }
    return environment.format("categories.limit.refused", table: "Settings", name, reason)
  }

  /// The write behind a limit field: `budgets` as the database has them now, `tree` the whole
  /// tree, archived categories included; `limitless` the reconciliation categories. Nil when the
  /// write landed or there was nothing to write, else the key, in the Planning table, of why not.
  static func commitLimit(
    _ text: String, for categoryId: UUID, budgets: [Budget], tree: CategoryTree,
    month: MonthKey, store: TransactionsStore, limitless: Set<UUID> = []
  ) -> String? {
    LimitWrites.setCategoryLimit(
      categoryId, typed: text, budgets: budgets, tree: tree, month: month, store: store,
      limitless: limitless)
  }

  /// Whether a new category of `kind` may be filed under `parent`: under nothing, or under
  /// a live root of the same kind (two levels, `kind` expense or income).
  ///
  /// The picker offers only those, but its choice outlives what it offered: until 24.09 a
  /// root chosen under «Расходы» stayed chosen when the switch went to «Доходы», and an income
  /// category was saved under an expense root — listed there with a quality picker, reported
  /// by the tree as an expense, offered by no form. The schema ties nothing to the parent's
  /// kind, so this is the check.
  static func acceptsParent(
    _ parent: UUID?, for kind: CategoryKind, in categories: [CoreKit.Category]
  ) -> Bool {
    NewReference.acceptsParent(parent, for: kind, in: categories)
  }

  /// What came of «Добавить».
  enum AddOutcome: Equatable {
    /// A new category, or the one the archive gave back: its id.
    case added(UUID)
    /// `parent` cannot take a category of the kind (`acceptsParent`).
    case parentRefused
    /// The database did not take the write; the journal says why.
    case failed
  }

  /// «Добавить»: a new category, made the way «Add…» of the ↓ panel makes one
  /// (`NewReference`) — and like there, a name the archive holds beside the same parent brings
  /// that category back instead of making a second one.
  static func add(
    named name: String, kind: CategoryKind, parent: UUID?, references: ReferenceRepository
  ) -> AddOutcome {
    let all = (try? references.categories(includeArchived: true)) ?? []
    guard let category = NewReference.category(named: name, kind: kind, parent: parent, among: all)
    else { return .parentRefused }
    if let archived = NewReference.archivedCategory(
      named: name, kind: kind, parent: parent, among: all)
    {
      let restored = AppEnvironment.attempt("categories.add", on: references) {
        try $0.restoreCategory(archived.id)
      }
      guard restored else { return .failed }
      return .added(archived.id)
    }
    guard AppEnvironment.attempt("categories.add", on: references, { try $0.save(category) })
    else { return .failed }
    return .added(category.id)
  }

  private func add() {
    guard let references = environment.references else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    switch Self.add(named: name, kind: kind, parent: newParent, references: references) {
    case .parentRefused:
      newParent = nil
      refusalKey = "categories.add.parentRefused"
      return
    case .failed:
      refused = true
      return
    case .added:
      break
    }
    newName = ""
    reload()
    environment.scheduleBackup()
  }
}

/// The monthly limit of one category, in its row: the amount as the app writes amounts, or
/// empty without a limit. What is typed is written on Return, when the field loses focus and
/// when the row goes away with the tab or the window — never per keystroke (`LimitFieldDraft`);
/// Esc puts the stored amount back. ↻ follows a limit whose leftover carries over to the next
/// month.
struct CategoryLimitField: View {
  @Dependency(\.environment) private var environment
  static let width: CGFloat = 132
  let stored: Budget?
  /// Writes what was typed; false when nothing was written, the reason said under the list.
  let commit: (String) -> Bool
  /// Esc: a reason said about this row goes with the typing.
  let cancel: () -> Void
  @State private var draft: LimitFieldDraft
  @FocusState private var focused: Bool

  init(stored: Budget?, commit: @escaping (String) -> Bool, cancel: @escaping () -> Void) {
    self.stored = stored
    self.commit = commit
    self.cancel = cancel
    _draft = State(initialValue: LimitFieldDraft(showing: Self.text(of: stored)))
  }

  var body: some View {
    HStack(spacing: 4) {
      TextField(text: Binding(get: { draft.text }, set: { draft.type($0) })) {
        Text(verbatim: environment.language("categories.limit.placeholder", table: "Settings"))
      }
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .appFont(.body.monospacedDigit())
      .multilineTextAlignment(.trailing)
      .focused($focused)
      .help(environment.language("categories.limit.placeholder", table: "Settings"))
      .accessibilityIdentifier("categories.row.limit")
      .onSubmit {
        if draft.submit(shown: shown, write: commit) == .written { focused = false }
      }
      .onExitCommand {
        draft.cancel(shown: shown)
        cancel()
      }
      .onChange(of: focused) { _, now in
        if !now { draft.leave(shown: shown, write: commit) }
      }
      Image(systemName: "arrow.clockwise")
        .foregroundStyle(.secondary)
        .opacity(stored?.rollover == true ? 1 : 0)
        .help(rollover)
        .accessibilityLabel(Text(verbatim: rollover))
        .accessibilityHidden(stored?.rollover != true)
    }
    .frame(width: Self.width)
    .onAppear { draft.storedChanged(to: shown) }
    // The name field of the row saves on the way out too: typed without Return, a limit was
    // lost when the tab switched to income or the window closed.
    .onDisappear { draft.leave(shown: shown, write: commit) }
    // The stored limit changed — written here, elsewhere or taken back by ⌘Z: shown at once,
    // unless the owner has typed over it.
    .onChange(of: stored) { _, _ in draft.storedChanged(to: shown) }
  }

  private var rollover: String {
    environment.language("categories.limit.rollover", table: "Settings")
  }

  /// The stored amount as the app writes amounts; nothing without a limit.
  private var shown: String { Self.text(of: stored) }

  private static func text(of stored: Budget?) -> String {
    stored.map { AmountField.text(for: $0.amountE4) } ?? ""
  }
}

/// What the limit field of a category's row holds between the stored limit and the owner's
/// typing. The stored limit shows whenever the owner has not typed over it — with the cursor
/// in the field too, so an amount ⌘Z took back shows at once — and only what the owner typed
/// is ever written: leaving a field that shows what the database has writes nothing. Until
/// 25.09 the field kept what it had written while it held the cursor, and leaving it wrote
/// that again after ⌘Z, the undo silently redone.
@MainActor
struct LimitFieldDraft {
  private(set) var text: String
  /// Typed by the owner since the field last showed the stored limit or wrote what it said.
  private(set) var isTyped = false

  init(showing shown: String) {
    text = shown
  }

  /// What a Return, or leaving the field, did.
  enum Submit: Equatable {
    /// Nothing was typed, or nothing new.
    case nothing
    /// The write landed (one step of ⌘Z), or what was typed says what is stored. The field
    /// lets go of the cursor then: the next ⌘Z takes back the write, not the typing in it.
    case written
    /// Nothing was written; the reason is said under the list.
    case refused
  }

  /// The owner typed, or took typing back in the field.
  mutating func type(_ new: String) {
    guard new != text else { return }
    text = new
    isTyped = true
  }

  /// The stored limit changed — written here, elsewhere, or taken back by ⌘Z.
  mutating func storedChanged(to shown: String) {
    if !isTyped { text = shown }
  }

  /// Return: what was typed is written and shown the way the app writes amounts. A refusal
  /// keeps it in the field, next to its reason, for the owner to correct.
  mutating func submit(shown: String, write: (String) -> Bool) -> Submit {
    guard isTyped else { return .nothing }
    guard text != shown else {
      isTyped = false
      return .nothing
    }
    guard write(text) else { return .refused }
    text = LimitWrites.settledText(text) ?? text
    isTyped = false
    return .written
  }

  /// The cursor left the field, or its row went away with the tab or the window: what was
  /// typed is written. A refusal gives the field back the stored limit — the reason stays said
  /// under the list — rather than leaving an amount on screen the database does not have.
  @discardableResult
  mutating func leave(shown: String, write: (String) -> Bool) -> Submit {
    let outcome = submit(shown: shown, write: write)
    if outcome == .refused { cancel(shown: shown) }
    return outcome
  }

  /// Esc: the stored limit again, the typing dropped.
  mutating func cancel(shown: String) {
    text = shown
    isTyped = false
  }
}

/// A new quality of a category and the operations it would re-rate if the past follows.
struct PastQualityQuestion: Identifiable {
  let change: CategoryQualityChange
  let ids: [UUID]

  var id: UUID { change.categoryId }
}

/// The words of the question, kept apart from the dialog so a test can read them.
@MainActor
enum CategoryQualityText {
  static func title(_ language: AppLanguage) -> String {
    language("categories.pastQuality.title", table: table)
  }

  /// «Оценка изменится у N операций. Оценки, поставленные вручную, не меняются.»
  static func message(_ count: Int, _ language: AppLanguage) -> String {
    language.format("categories.pastQuality.message", table: table, counts: count)
  }

  static func apply(_ language: AppLanguage) -> String {
    language("categories.pastQuality.apply", table: table)
  }

  static func keep(_ language: AppLanguage) -> String {
    language("categories.pastQuality.keep", table: table)
  }

  private static let table = "Settings"
}

/// The words of the question asked before a category goes, apart from the sheet so a test
/// reads them in both languages.
@MainActor
enum CategoryDeletionText {
  /// The count goes in as a plural of its own, verb included — «лежит 1 операция», «лежат
  /// 2 операции» — one argument per plural, as everywhere in the catalogs.
  static func message(
    _ question: CategoriesSettingsView.CategoryDeletion, _ language: AppLanguage
  ) -> String {
    let name = question.category.name
    func sentence(_ key: String, _ plural: String, _ count: Int) -> String {
      language.format(
        key, table: table, name, language.format(plural, table: table, counts: count))
    }
    if question.blocked {
      return sentence(
        "categories.delete.blocked", "categories.delete.blocked.count", question.binned)
    }
    if question.live > 0 {
      return sentence("categories.delete.used", "categories.delete.used.count", question.live)
    }
    if question.children > 0 {
      return sentence(
        "categories.delete.withChildren", "categories.delete.withChildren.count",
        question.children)
    }
    return language.format("categories.delete.free", table: table, name)
  }

  private static let table = "Settings"
}

/// The question asked before a category goes: what points at it, where its operations move,
/// and the two ways out. A sheet rather than a dialog — a dialog cannot hold a picker.
private struct CategoryDeletionSheet: View {
  @Dependency(\.environment) private var environment
  let question: CategoriesSettingsView.CategoryDeletion
  @Binding var moveTo: UUID?
  let options: [(id: UUID, name: String)]
  let title: String
  let message: String
  let archive: () -> Void
  let delete: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: title)
        .appFont(.headline)
      Text(verbatim: message)
        .fixedSize(horizontal: false, vertical: true)

      if question.live > 0, !question.blocked {
        Picker(selection: $moveTo) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(options, id: \.id) { option in
            Text(verbatim: option.name).tag(UUID?.some(option.id))
          }
        } label: {
          Text(verbatim: environment.language("categories.delete.moveTo", table: "Settings"))
        }
        .accessibilityIdentifier("categories.delete.moveTo")
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        if question.blocked {
          Button(environment.language("references.archive", table: "Settings"), action: archive)
            .buttonStyle(.borderedProminent)
        } else {
          Button(
            environment.language("references.delete", table: "Settings"), role: .destructive,
            action: delete
          )
          .buttonStyle(.borderedProminent)
          .disabled(question.live > 0 && moveTo == nil)
          .accessibilityIdentifier("categories.delete.confirm")
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
  }
}

/// «Необходимая трата» of a category: its own yes or no, or — for a subcategory — what the
/// category above says.
enum EssentialChoice: String, CaseIterable, Hashable {
  case inherit
  case yes
  case no

  /// What is stored; on a category at the top nothing means no.
  init(_ value: Bool?, isTop: Bool = false) {
    switch value {
    case true?: self = .yes
    case false?: self = .no
    case nil: self = isTop ? .no : .inherit
    }
  }

  var value: Bool? {
    switch self {
    case .inherit: nil
    case .yes: true
    case .no: false
    }
  }
}
