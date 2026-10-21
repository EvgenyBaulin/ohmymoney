import Foundation

/// The ids the places of the app mark themselves with, as the steps of the guide name them. A
/// view marks its place with the same string; a place missing from the window gets the words
/// alone.
public enum GuideTarget {
  public static let entryLine = "entry.line"
  public static let entryDetails = "entry.details.toggle"
  public static let entryForWhom = "entry.forWhom"
  public static let entryQuick = "entry.quick"

  public static let sidebarOverview = "sidebar.overview"
  public static let sidebarPlanning = "sidebar.planning"
  public static let sidebarDebts = "sidebar.debts"
  public static let sidebarOperations = "sidebar.operations"
  public static let sidebarCalendar = "sidebar.calendar"
  public static let sidebarCapital = "sidebar.capital"

  public static let operationsSearch = "transactions.search"
  public static let operationsList = "operations.list"
  public static let planningAddPayment = "planning.addPayment"
  public static let planningAddGoal = "planning.addGoal"
  public static let planningFreeToSpend = "planning.freeToSpend"
  public static let debtsAdd = "debts.add"

  /// Drawn by AppKit or in another window: never framed, the words say where they are.
  public static let toolbarTransactions = "toolbar.transactions"
  public static let toolbarReconcile = "toolbar.reconcile"
  public static let toolbarSettings = "toolbar.settings"
  public static let settingsAccounts = "settings.accounts"
  public static let settingsOverviewTiles = "settings.overviewTiles"

  /// The places that are not in the main window's content: no step expects a frame there.
  public static let outsideTheContent: Set<String> = [
    toolbarTransactions, toolbarReconcile, toolbarSettings, settingsAccounts,
    settingsOverviewTiles,
  ]
}
