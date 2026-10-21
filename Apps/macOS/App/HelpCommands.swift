import AppCore
import AppKit
import SwiftUI

/// The Help menu: the guide — «Знакомство с OhMyMoney», «Что нового», «Учебный режим» and «Показать,
/// куда нажимать» — and the item that matters when something has broken, «Собрать отчёт о
/// проблеме…».
///
/// It opens the report itself, gathered, on a sheet over the settings: the list of what goes
/// into the file is shown before the file is written. It used to open the settings alone — on
/// whatever tab they were left, with the report at the bottom of the General one, below the
/// fold.
struct HelpCommands: Commands {
  /// The same public action the gear of the toolbar uses. It replaced
  /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` — a private selector Apple renamed
  /// once already, between macOS 13 and 14.
  @Environment(\.openSettings) private var openSettings
  let environment: AppEnvironment

  var body: some Commands {
    CommandGroup(replacing: .help) {
      Button(environment.language("guide.menu.tour", table: "Guide")) {
        AppWindows.intoMain { GuideStore.shared.show(GuideCatalog.firstLaunch) }
      }
      Button(environment.language("guide.menu.whatsNew", table: "Guide")) {
        AppWindows.intoMain {
          if let latest = GuideCatalog.whatsNew.last { GuideStore.shared.show(latest) }
        }
      }
      Button(environment.language("guide.menu.whereToClick", table: "Guide")) {
        AppWindows.intoMain { GuideStore.shared.showsWhereToClick = true }
      }
      Divider()
      if GuideStore.shared.isTutorial {
        Button(environment.language("guide.tutorial.exit", table: "Guide")) {
          GuideActions.leaveTutorial()
        }
        Button(environment.language("guide.menu.restart", table: "Guide")) {
          GuideActions.restartTutorial()
        }
      } else {
        Button(environment.language("guide.menu.tutorial", table: "Guide")) {
          GuideActions.enterTutorial()
        }
      }
      Divider()
      Button(environment.language("report.title", table: "Settings")) {
        Self.collectReport(environment) { openSettings() }
      }
      Button(environment.language("report.showJournal", table: "Settings")) {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logsDirectory])
      }
    }
  }

  /// What «Собрать отчёт о проблеме…» does: the settings open with the report over them.
  @MainActor
  static func collectReport(_ environment: AppEnvironment, openSettings: () -> Void) {
    environment.showsProblemReport = true
    openSettings()
  }
}
