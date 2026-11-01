import AppCore
import AppKit
import Foundation

// The AppleScript commands of `OhMyMoney.sdef`. Each one hands its arguments to `MacCommands`
// — what «Быстрые команды» call too — and answers with its words. A command is run on the main
// thread by AppKit; it suspends the script's reply while the app answers, so a launch that is
// still opening the database is waited for (`MacCommandsHost`).

/// What every command of the dictionary shares: suspending the reply and answering with text.
class OhMyMoneyScriptCommand: NSScriptCommand {
  /// The answer of the command. Called on the main actor.
  @MainActor
  func answer(_ commands: MacCommands) async -> String { "" }

  override func performDefaultImplementation() -> Any? {
    suspendExecution()
    // AppKit runs a script command on the main thread and keeps it until it is resumed; the
    // task below runs there too, so the command never crosses a thread.
    nonisolated(unsafe) let command = self
    Task { @MainActor in
      let text: String
      if let commands = await MacCommandsHost.commands() {
        text = await command.answer(commands)
      } else {
        text = MacCommandsHost.notReady
      }
      command.resumeExecution(withResult: text)
    }
    return nil
  }

  var text: String? { directParameter as? String }

  func argument<Value>(_ key: String) -> Value? { evaluatedArguments?[key] as? Value }

  var confirmed: Bool { argument("confirmed") ?? false }
}

@objc(OhMyMoneyAddOperationCommand)
final class OhMyMoneyAddOperationCommand: OhMyMoneyScriptCommand {
  @MainActor
  override func answer(_ commands: MacCommands) async -> String {
    await commands.add(line: text ?? "", confirmed: confirmed).text
  }
}

@objc(OhMyMoneyEditOperationCommand)
final class OhMyMoneyEditOperationCommand: OhMyMoneyScriptCommand {
  @MainActor
  override func answer(_ commands: MacCommands) async -> String {
    guard let id = text.flatMap(UUID.init(uuidString:)) else {
      return commands.t("mac.command.notFound")
    }
    var amount: Decimal?
    if let typed: String = argument("amount") {
      guard let read = CommandAmount.read(typed) else {
        return commands.environment.language("entry.error.badExpression", table: "Entry")
      }
      amount = read
    }
    return commands.edit(
      id, description: argument("note"), amount: amount, category: argument("category"),
      confirmed: confirmed
    ).text
  }
}

@objc(OhMyMoneyDeleteOperationCommand)
final class OhMyMoneyDeleteOperationCommand: OhMyMoneyScriptCommand {
  @MainActor
  override func answer(_ commands: MacCommands) async -> String {
    guard let id = text.flatMap(UUID.init(uuidString:)) else {
      return commands.t("mac.command.notFound")
    }
    return commands.delete(id).text
  }
}

@objc(OhMyMoneyFindOperationsCommand)
final class OhMyMoneyFindOperationsCommand: OhMyMoneyScriptCommand {
  @MainActor
  override func answer(_ commands: MacCommands) async -> String {
    if let refusal = commands.refusal(writes: false) { return refusal }
    let limit = max(1, argument("limit") ?? 50)
    return commands.operations(matching: text ?? "", limit: limit)
      .map { "\($0.id.uuidString.lowercased())\t\($0.day.iso)\t\($0.title)\t\($0.amount)" }
      .joined(separator: "\n")
  }
}

@objc(OhMyMoneyMonthSummaryCommand)
final class OhMyMoneyMonthSummaryCommand: OhMyMoneyScriptCommand {
  @MainActor
  override func answer(_ commands: MacCommands) async -> String {
    let typed: String? = argument("month")
    var month: MonthKey?
    if let typed {
      guard let key = MonthKey(iso: typed.trimmingCharacters(in: .whitespaces)) else {
        return commands.t("mac.command.badMonth")
      }
      month = key
    }
    return commands.monthSummary(month).text
  }
}
