import AppCore
import AppIntents
import Foundation
import UniformTypeIdentifiers

// The actions of OhMyMoney in «Быстрые команды» (Shortcuts) on the Mac. Each one is a thin
// wrapper over `MacCommands`, which AppleScript calls too: what they can do, what they refuse and
// what they say is decided there, not here.

/// Why an action did nothing, in the words `MacCommands` chose.
struct CommandRefusal: Error, CustomLocalizedStringResourceConvertible {
  let text: String
  var localizedStringResource: LocalizedStringResource {
    LocalizedStringResource(stringLiteral: text)
  }
}

@MainActor
private func commands() async throws -> MacCommands {
  guard let commands = await MacCommandsHost.commands() else {
    throw CommandRefusal(text: MacCommandsHost.notReady)
  }
  return commands
}

/// The month a date falls in; the last finished month without one.
@MainActor
private func monthKey(of date: Date?, _ commands: MacCommands) -> MonthKey {
  guard let date else { return commands.environment.today.monthKey.previous }
  return commands.environment.calendar.day(of: date).monthKey
}

// MARK: - Operations as Shortcuts knows them

struct OperationEntity: AppEntity, Identifiable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("intent.operation.type", table: "MacFeatures"))
  static let defaultQuery = OperationQuery()

  let id: UUID
  let title: String
  let subtitle: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: title),
      subtitle: LocalizedStringResource(stringLiteral: subtitle))
  }

  @MainActor
  init(_ operation: CommandOperation) {
    id = operation.id
    title = operation.title
    subtitle = "\(operation.day.iso) · \(operation.amount)"
  }
}

struct OperationQuery: EntityStringQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [OperationEntity] {
    try await commands().operations(ids: identifiers).map(OperationEntity.init)
  }

  @MainActor
  func entities(matching string: String) async throws -> [OperationEntity] {
    try await commands().operations(matching: string).map(OperationEntity.init)
  }

  @MainActor
  func suggestedEntities() async throws -> [OperationEntity] {
    try await commands().operations(matching: "", limit: 20).map(OperationEntity.init)
  }
}

// MARK: - Writing

/// «Добавить операцию»: a line as the entry line reads it — «кофе 250», «+50000 зарплата»,
/// «перевод 5000 сбер т-банк».
struct AddOperationIntent: AppIntent {
  static let title = LocalizedStringResource("intent.add.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.add.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.add.line", table: "MacFeatures"))
  var line: String

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let commands = try await commands()
    var outcome = await commands.add(line: line)
    if case .question(let question) = outcome {
      try await requestConfirmation(
        dialog: IntentDialog(LocalizedStringResource(stringLiteral: question)))
      outcome = await commands.add(line: line, confirmed: true)
    }
    return try finish(outcome)
  }
}

/// «Изменить операцию»: the description, the amount or the category; what is left empty stays.
struct EditOperationIntent: AppIntent {
  static let title = LocalizedStringResource("intent.edit.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.edit.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.operation", table: "MacFeatures"))
  var operation: OperationEntity

  @Parameter(title: LocalizedStringResource("intent.edit.note", table: "MacFeatures"))
  var note: String?

  /// Text, not a number: an amount is never a floating-point value in this app.
  @Parameter(title: LocalizedStringResource("intent.edit.amount", table: "MacFeatures"))
  var amount: String?

  @Parameter(title: LocalizedStringResource("intent.edit.category", table: "MacFeatures"))
  var category: String?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let commands = try await commands()
    var decimal: Decimal?
    if let amount, !amount.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let read = CommandAmount.read(amount) else {
        throw CommandRefusal(
          text: commands.environment.language("entry.error.badExpression", table: "Entry"))
      }
      decimal = read
    }
    var outcome = commands.edit(
      operation.id, description: note, amount: decimal, category: category)
    if case .question(let question) = outcome {
      try await requestConfirmation(
        dialog: IntentDialog(LocalizedStringResource(stringLiteral: question)))
      outcome = commands.edit(
        operation.id, description: note, amount: decimal, category: category, confirmed: true)
    }
    return try finish(outcome)
  }
}

/// «Удалить операцию»: as «Удалить» in the list — one step of ⌘Z brings it back.
struct DeleteOperationIntent: AppIntent {
  static let title = LocalizedStringResource("intent.delete.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.delete.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.operation", table: "MacFeatures"))
  var operation: OperationEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    try finish(try await commands().delete(operation.id))
  }
}

// MARK: - Reading

/// «Найти операции»: by a word of the description, the place or the category.
struct FindOperationsIntent: AppIntent {
  static let title = LocalizedStringResource("intent.find.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.find.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.find.text", table: "MacFeatures"))
  var text: String

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[OperationEntity]> {
    let commands = try await commands()
    if let refusal = commands.refusal(writes: false) { throw CommandRefusal(text: refusal) }
    return .result(value: commands.operations(matching: text).map(OperationEntity.init))
  }
}

/// «Сводка месяца»: the summary of a month as text — the figures of «Итоги».
struct MonthSummaryIntent: AppIntent {
  static let title = LocalizedStringResource("intent.summary.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.summary.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.month", table: "MacFeatures"))
  var month: Date?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let commands = try await commands()
    return try finish(commands.monthSummary(monthKey(of: self.month, commands)))
  }
}

/// «Экспорт месяца в Markdown»: the same summary as a file, for «Сохранить файл» of Shortcuts —
/// which is how it goes into a folder on a schedule.
struct ExportMonthMarkdownIntent: AppIntent {
  static let title = LocalizedStringResource("intent.markdown.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.markdown.description", table: "MacFeatures"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.month", table: "MacFeatures"))
  var month: Date?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
    let commands = try await commands()
    let key = monthKey(of: self.month, commands)
    guard case .done(let text) = commands.monthSummary(key) else {
      throw CommandRefusal(text: commands.monthSummary(key).text)
    }
    let file = IntentFile(
      data: Data(text.utf8), filename: MonthMarkdownExport.fileName(key), type: .plainText)
    return .result(value: file)
  }
}

@MainActor
private func finish(
  _ outcome: CommandOutcome
) throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
  switch outcome {
  case .done(let text):
    return .result(value: text, dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
  case .question(let text), .refused(let text):
    throw CommandRefusal(text: text)
  }
}

// MARK: - Focus

/// The filter of a Focus: «Скрыть суммы» while the Focus is on. It switches nothing else; amounts
/// the owner hid before the Focus began stay hidden after it (`FocusAmounts`). The switch is off
/// by default because the system runs the filter with its default values when the Focus ends.
struct AmountsFocusFilter: SetFocusFilterIntent {
  static let title = LocalizedStringResource("intent.focus.title", table: "MacFeatures")
  static let description = IntentDescription(
    LocalizedStringResource("intent.focus.description", table: "MacFeatures"))

  @Parameter(
    title: LocalizedStringResource("intent.focus.hide", table: "MacFeatures"), default: false)
  var hideAmounts: Bool

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: hideAmounts
        ? LocalizedStringResource("intent.focus.hidden", table: "MacFeatures")
        : LocalizedStringResource("intent.focus.shown", table: "MacFeatures"))
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    FocusAmountsSwitch.apply(focusHides: hideAmounts)
    return .result()
  }
}
