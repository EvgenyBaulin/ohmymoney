import AppCore
import AppIntents
import AppKit
import Foundation

/// «Передать сообщение банка»: the text of an SMS or a push, passed on by «Быстрые команды» —
/// by hand, or by an automation — is read and written or offered as the owner chose
/// (`AutoEntryCenter`). The text is read and forgotten; only what was read out of it is kept.
struct PassBankMessageIntent: AppIntent {
  static let title = LocalizedStringResource("intent.bankMessage.title", table: "AutoEntry")
  static let description = IntentDescription(
    LocalizedStringResource("intent.bankMessage.description", table: "AutoEntry"))
  static let openAppWhenRun = false

  @Parameter(title: LocalizedStringResource("intent.bankMessage.text", table: "AutoEntry"))
  var text: String

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    try await AutoEntryIntentRun.finish { center, commands in
      await center.receive(text, commands: commands)
    }
  }
}

/// «Передать сообщение банка из буфера»: the text copied on the Mac — a push read on the phone
/// and copied through the shared pasteboard, an SMS in «Сообщения».
struct PassPasteboardBankMessageIntent: AppIntent {
  static let title = LocalizedStringResource("intent.bankPasteboard.title", table: "AutoEntry")
  static let description = IntentDescription(
    LocalizedStringResource("intent.bankPasteboard.description", table: "AutoEntry"))
  static let openAppWhenRun = false

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    try await AutoEntryIntentRun.finish { center, commands in
      await center.receivePasteboard(
        NSPasteboard.general.string(forType: .string), commands: commands)
    }
  }
}

@MainActor
enum AutoEntryIntentRun {
  static func finish(
    _ run: (AutoEntryCenter, MacCommands) async -> AutoEntryCenter.Result
  ) async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard let commands = await MacCommandsHost.commands() else {
      throw CommandRefusal(text: MacCommandsHost.notReady)
    }
    let result = await run(AutoEntryCenter.shared, commands)
    await MacNotifications.shared.post(result)
    switch result.outcome {
    case .done(let text):
      return .result(
        value: text, dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    case .question(let text), .refused(let text):
      throw CommandRefusal(text: text)
    }
  }
}
