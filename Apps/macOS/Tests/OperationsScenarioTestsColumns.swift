import AppCore
import XCTest

@testable import OhMyMoney

/// The columns of «Операции» as «Настроить столбцы…» edits them and this Mac keeps them under
/// `operations.columns`: every column has sane bounds and a title in both languages, the text
/// read back is the layout written, a text of another version or a damaged one is read safely,
/// the description and the amount can never be hidden, and widths stay within their bounds.
final class OperationsScenarioColumnsTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    suiteName = "ohmymoney.tests.b.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() {
    defaults?.removePersistentDomain(forName: suiteName)
    defaults = nil
  }

  private static func localized(_ key: String, _ language: String) -> String {
    Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))?
      .localizedString(forKey: key, value: nil, table: "Transactions") ?? key
  }

  // MARK: The columns themselves

  func testEveryColumnHasBoundsAroundItsStandardWidth() {
    for column in OperationColumn.allCases {
      XCTAssertGreaterThan(column.minimumWidth, 0, "\(column)")
      XCTAssertLessThanOrEqual(column.minimumWidth, column.standardWidth, "\(column)")
      XCTAssertLessThanOrEqual(column.standardWidth, column.maximumWidth, "\(column)")
    }
  }

  func testOnlyTheDescriptionAndTheAmountCannotBeHidden() {
    let fixed = OperationColumn.allCases.filter { !$0.canBeHidden }
    XCTAssertEqual(fixed, [.description, .amount])
  }

  /// The design's five columns are shown; the rest wait for the owner.
  func testOnlyTheFiveColumnsOfTheDesignAreShownByDefault() {
    XCTAssertEqual(
      OperationColumn.allCases.filter(\.shownByDefault),
      [.description, .category, .account, .time, .amount])
    XCTAssertEqual(
      OperationColumn.allCases.filter { !$0.shownByDefault },
      [.place, .forWhom, .quality, .cashback, .note, .event, .mcc])
  }

  func testOnlyTheAmountAndTheCashbackLineUpOnTheRight() {
    XCTAssertEqual(OperationColumn.allCases.filter(\.isNumeric), [.amount, .cashback])
  }

  func testTheIdIsTheRawValueKeptInTheText() {
    for column in OperationColumn.allCases {
      XCTAssertEqual(column.id, column.rawValue)
      XCTAssertEqual(OperationColumn(rawValue: column.rawValue), column)
    }
  }

  func testTheAccountColumnKeepsTheOldTitleKey() {
    XCTAssertEqual(OperationColumn.account.titleKey, "transactions.column.paymentMethod")
    XCTAssertEqual(OperationColumn.place.titleKey, "transactions.column.place")
  }

  func testEveryColumnHasAnEnglishTitle() {
    for column in OperationColumn.allCases {
      let english = Self.localized(column.titleKey, "en")
      XCTAssertNotEqual(english, column.titleKey, "\(column)")
      XCTAssertFalse(english.isEmpty, "\(column)")
    }
  }

  func testTheRussianAndEnglishTitlesDiffer() {
    // The code of the merchant category is an abbreviation that reads the same in both.
    for column in OperationColumn.allCases where column != .mcc {
      XCTAssertNotEqual(
        Self.localized(column.titleKey, "ru"), Self.localized(column.titleKey, "en"), "\(column)")
    }
    XCTAssertEqual(Self.localized(OperationColumn.mcc.titleKey, "ru"), "MCC")
    XCTAssertEqual(Self.localized(OperationColumn.mcc.titleKey, "en"), "MCC")
  }

  func testTheMerchantCodeColumnIsHiddenUntilTheOwnerShowsIt() {
    XCTAssertFalse(OperationColumn.mcc.shownByDefault)
    XCTAssertTrue(OperationColumn.mcc.canBeHidden)
    XCTAssertFalse(OperationColumn.mcc.isNumeric)
    XCTAssertEqual(OperationColumn.mcc.titleKey, "transactions.column.mcc")
    XCTAssertTrue(OperationColumnLayout.standard.storage.hasSuffix("-event,-mcc"))
    // A layout kept by an older build, with no word of it, shows the new column hidden.
    let older = OperationColumnLayout(
      storage:
        "description,category,account,time,amount,-place,-forWhom,-quality,-cashback,-note,-event")
    XCTAssertEqual(older, .standard)
  }

  // MARK: The text kept on this Mac

  func testTheStandardTextNamesEveryColumnInOrderWithTheOthersHidden() {
    XCTAssertEqual(
      OperationColumnLayout.standard.storage,
      "description,category,account,time,amount,-place,-forWhom,-quality,-cashback,-note,-event,-mcc"
    )
  }

  func testATextOfCommasAloneIsTheStandardLayout() {
    XCTAssertEqual(OperationColumnLayout(storage: ",,, ,"), .standard)
  }

  func testATextNamingNothingKnownIsTheStandardLayout() {
    XCTAssertEqual(OperationColumnLayout(storage: "date,sum,payee"), .standard)
  }

  func testNamesAreReadExactlyAsTheyAreWritten() {
    let layout = OperationColumnLayout(storage: "TIME,-Place")
    XCTAssertEqual(layout, .standard, "names in another case are not columns")
  }

  func testADoubledDashIsNotAColumn() {
    let layout = OperationColumnLayout(storage: "--place")
    XCTAssertFalse(layout.isShown(.place), "the standard layout, where the place is hidden")
    XCTAssertEqual(layout, .standard)
  }

  func testTheEventAloneComesShownInItsStandardPlace() {
    let layout = OperationColumnLayout(storage: "event")
    XCTAssertEqual(layout.order, OperationColumn.allCases)
    XCTAssertTrue(layout.isShown(.event))
  }

  /// The named columns keep their order; the others take their standard places around them —
  /// the description, first in the standard order, before them all.
  func testTheColumnsNotNamedTakeTheirStandardPlacesAroundTheNamedOnes() {
    let layout = OperationColumnLayout(storage: "note,time")
    XCTAssertEqual(
      layout.order,
      [
        .description, .category, .account, .note, .time, .amount, .place, .forWhom, .quality,
        .cashback, .event, .mcc,
      ])
  }

  func testAHiddenColumnKeepsItsWidth() {
    let layout = OperationColumnLayout(storage: "-place:150")
    XCTAssertFalse(layout.isShown(.place))
    XCTAssertEqual(layout.width(of: .place), 150)
    XCTAssertTrue(layout.storage.contains("-place:150"))
  }

  func testTheDescriptionWrittenHiddenIsShownWithItsWidth() {
    let layout = OperationColumnLayout(storage: "-description:300")
    XCTAssertTrue(layout.isShown(.description))
    XCTAssertEqual(layout.width(of: .description), 300)
  }

  func testANegativeWidthIsTheMinimum() {
    let layout = OperationColumnLayout(storage: "note:-40")
    XCTAssertEqual(layout.width(of: .note), OperationColumn.note.minimumWidth)
  }

  func testAWidthThatIsNotANumberLeavesTheStandardWidth() {
    let layout = OperationColumnLayout(storage: "category:wide")
    XCTAssertEqual(layout.width(of: .category), OperationColumn.category.standardWidth)
    XCTAssertFalse(layout.storage.contains("category:"))
  }

  func testAWidthTooLargeForANumberLeavesTheStandardWidth() {
    let layout = OperationColumnLayout(storage: "note:99999999999999999999999")
    XCTAssertEqual(layout.width(of: .note), OperationColumn.note.standardWidth)
  }

  func testAWidthBeyondTheMaximumIsTheMaximum() {
    let layout = OperationColumnLayout(storage: "time:5000")
    XCTAssertEqual(layout.width(of: .time), OperationColumn.time.maximumWidth)
  }

  func testAnItemWithSpacesAroundItIsRead() throws {
    let layout = OperationColumnLayout(storage: "  note:200 , time ")
    let note = try XCTUnwrap(layout.order.firstIndex(of: .note))
    XCTAssertEqual(Array(layout.order[note...(note + 1)]), [.note, .time])
    XCTAssertEqual(layout.width(of: .note), 200)
  }

  func testTheTextReadBackIsWrittenTheSame() {
    let texts = [
      "time,description:220,amount,-event:90",
      "note,-place,cashback:120,description,amount",
      OperationColumnLayout.standard.storage,
    ]
    for text in texts {
      let once = OperationColumnLayout(storage: text)
      XCTAssertEqual(OperationColumnLayout(storage: once.storage), once, text)
      XCTAssertEqual(OperationColumnLayout(storage: once.storage).storage, once.storage, text)
    }
  }

  func testEveryColumnIsInTheOrderExactlyOnce() {
    let layout = OperationColumnLayout(storage: "amount,amount,time,amount:300,note,note")
    XCTAssertEqual(layout.order.count, OperationColumn.allCases.count)
    XCTAssertEqual(Set(layout.order), Set(OperationColumn.allCases))
    XCTAssertEqual(
      layout.width(of: .amount), OperationColumn.amount.standardWidth,
      "a repeated name is dropped with its width")
  }

  func testTheLayoutIsKeptInTheDefaultsOfThisMacAndReadBack() {
    var layout = OperationColumnLayout.standard
    layout.setShown(false, .quality)
    layout.setWidth(250, of: .note)
    defaults.set(layout.storage, forKey: OperationColumnLayout.storageKey)
    let read = OperationColumnLayout(
      storage: defaults.string(forKey: OperationColumnLayout.storageKey))
    XCTAssertEqual(read, layout)
    defaults.removeObject(forKey: OperationColumnLayout.storageKey)
    XCTAssertEqual(
      OperationColumnLayout(storage: defaults.string(forKey: OperationColumnLayout.storageKey)),
      .standard, "«Сбросить» clears the text")
  }

  // MARK: Showing and hiding

  func testHidingEveryColumnLeavesTheDescriptionAndTheAmount() {
    var layout = OperationColumnLayout.standard
    for column in OperationColumn.allCases { layout.setShown(false, column) }
    XCTAssertEqual(layout.visible, [.description, .amount])
  }

  func testShowingEveryColumnShowsTheEventToo() {
    var layout = OperationColumnLayout.standard
    for column in OperationColumn.allCases { layout.setShown(true, column) }
    XCTAssertEqual(layout.visible, OperationColumn.allCases)
    XCTAssertFalse(layout.storage.contains("-"))
  }

  func testShowingAShownColumnChangesNothing() {
    var layout = OperationColumnLayout.standard
    layout.setShown(true, .category)
    XCTAssertEqual(layout, .standard)
  }

  func testHidingAndShowingAgainIsTheStandardLayout() {
    var layout = OperationColumnLayout.standard
    layout.setShown(false, .account)
    XCTAssertNotEqual(layout, .standard)
    layout.setShown(true, .account)
    XCTAssertEqual(layout, .standard)
  }

  func testAHiddenColumnKeepsItsPlaceInTheOrder() {
    var layout = OperationColumnLayout.standard
    layout.setShown(false, .category)
    XCTAssertEqual(layout.order, OperationColumn.allCases)
    XCTAssertFalse(layout.visible.contains(.category))
  }

  // MARK: Widths

  func testEveryWidthIsKeptWithinItsBounds() {
    for column in OperationColumn.allCases {
      var layout = OperationColumnLayout.standard
      layout.setWidth(0, of: column)
      XCTAssertEqual(layout.width(of: column), column.minimumWidth, "\(column)")
      layout.setWidth(Int.max, of: column)
      XCTAssertEqual(layout.width(of: column), column.maximumWidth, "\(column)")
      layout.setWidth(column.standardWidth + 1, of: column)
      XCTAssertEqual(
        layout.width(of: column), min(column.standardWidth + 1, column.maximumWidth), "\(column)")
    }
  }

  func testAWidthOfOneColumnLeavesTheOthersStandard() {
    var layout = OperationColumnLayout.standard
    layout.setWidth(333, of: .note)
    for column in OperationColumn.allCases where column != .note {
      XCTAssertEqual(layout.width(of: column), column.standardWidth, "\(column)")
    }
  }

  func testAWidthEqualToTheStandardIsStillWritten() {
    var layout = OperationColumnLayout.standard
    layout.setWidth(OperationColumn.place.standardWidth, of: .place)
    XCTAssertTrue(layout.storage.contains("place:\(OperationColumn.place.standardWidth)"))
    XCTAssertEqual(layout.width(of: .place), OperationColumn.place.standardWidth)
  }

  // MARK: Moving with the arrows

  func testTheLastColumnMovesNoFurtherDown() {
    var layout = OperationColumnLayout.standard
    layout.move(.mcc, by: 1)
    XCTAssertEqual(layout, .standard)
  }

  func testMovingDownAndUpAgainIsTheStandardOrder() {
    var layout = OperationColumnLayout.standard
    layout.move(.category, by: 1)
    XCTAssertEqual(Array(layout.order[1...2]), [.account, .category])
    layout.move(.category, by: -1)
    XCTAssertEqual(layout, .standard)
  }

  func testTheTimeCanBeMovedToTheEndStepByStep() {
    var layout = OperationColumnLayout.standard
    for _ in 0..<(OperationColumn.allCases.count + 3) { layout.move(.time, by: 1) }
    XCTAssertEqual(layout.order.last, .time)
    XCTAssertEqual(layout.order.first, .description)
  }

  // MARK: Dragging

  func testADragOfNothingMovesNothing() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [], toOffset: 4)
    XCTAssertEqual(layout, .standard)
  }

  func testADragOfRowsOutOfTheListMovesNothing() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [40, 99], toOffset: 0)
    XCTAssertEqual(layout, .standard)
  }

  func testADragBeyondTheEndPutsTheRowsLast() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [0], toOffset: 500)
    XCTAssertEqual(layout.order.last, .description)
  }

  func testADragBeforeTheStartPutsTheRowsFirst() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [10], toOffset: -3)
    XCTAssertEqual(layout.order.first, .event)
  }

  func testRowsDraggedApartLandTogetherInTheirOrder() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [3, 1], toOffset: 0)
    XCTAssertEqual(Array(layout.order.prefix(4)), [.category, .time, .description, .account])
  }

  func testADragKeepsTheWidthsAndTheHiddenColumns() {
    var layout = OperationColumnLayout.standard
    layout.setWidth(222, of: .note)
    layout.setShown(false, .place)
    layout.move(fromOffsets: [9], toOffset: 1)
    XCTAssertEqual(layout.order[1], .note)
    XCTAssertEqual(layout.width(of: .note), 222)
    XCTAssertFalse(layout.isShown(.place))
    XCTAssertEqual(OperationColumnLayout(storage: layout.storage), layout)
  }
}
