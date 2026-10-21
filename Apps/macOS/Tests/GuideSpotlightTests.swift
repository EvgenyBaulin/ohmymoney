import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The guide pointing at one place at a time: the window darkened with a cut-out exactly at the
/// place's frame on any window from 340 to 1400 points, in Russian and in English; the words
/// beside it inside the window; the steps in order; a click in the cut-out moving on, Esc
/// leaving; a place the window does not show getting its words in the middle.
@MainActor
final class GuideSpotlightTests: XCTestCase {
  private var suite = ""
  private var appGuide: GuideStore!
  private var guide: GuideStore!
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    suite = "ohmymoney.tests.guideSpotlight.\(UUID().uuidString)"
    appGuide = GuideStore.shared
    guide = GuideStore(defaults: UserDefaults(suiteName: suite) ?? .standard, tutorial: true)
    GuideStore.shared = guide
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    GuideStore.shared = appGuide
    UserDefaults().removePersistentDomain(forName: suite)
  }

  // MARK: Helpers

  private final class Box { var view: NSView? }

  /// An AppKit view filling the SwiftUI view it backs: its frame in the window is the place's.
  private struct Probe: NSViewRepresentable {
    let box: Box
    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      box.view = view
      return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func show<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: every caller hands them to its view with `.appDependencies`
    window.contentView = NSHostingView(rootView: view)
    window.setContentSize(CGSize(width: width, height: height))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  private func dependencies(_ language: AppLanguage.Choice) -> AppDependencies {
    let environment = AppEnvironment()
    environment.language.choice = language
    return AppDependencies(
      environment: environment, store: TransactionsStore(), compute: ComputeStore(calendar: .utc))
  }

  private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }

  private func frameInWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

  private static let place = "test.place"

  private func walk(_ targets: [String], click: Bool = true) -> GuideWalkthrough? {
    GuideWalkthrough(
      .whereToClick,
      steps: targets.map {
        GuideHint(
          target: $0, text: GuideText("Нажмите сюда", "Press here"),
          why: GuideText("Так быстрее всего.", "It is the quickest way."), advancesOnClick: click)
      })
  }

  /// A root with one marked place of 120 × 30 at `alignment`, the guide pointing at it.
  private func root(
    alignment: Alignment, language: AppLanguage.Choice, box: Box
  ) -> some View {
    ZStack(alignment: alignment) {
      Color.clear
      Color.gray
        .frame(width: 120, height: 30)
        .background(Probe(box: box))
        .guideTarget(Self.place)
        .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .guideOverlay(guide, toolbar: true)
    .appDependencies(dependencies(language))
  }

  private func assertTheCutOutIsThePlace(widths: [CGFloat]) {
    for width in widths {
      for language in [AppLanguage.Choice.russian, .english] {
        for alignment in [Alignment.topLeading, .center, .bottomTrailing, .leading] {
          let box = Box()
          guide.start(walk([Self.place]))
          let window = show(
            root(alignment: alignment, language: language, box: box), width: width, height: 560)
          let where_ = "\(language) \(Int(width)) \(alignment)"
          guard let place = box.view else {
            XCTFail("no place drawn: \(where_)")
            continue
          }
          let holes = views(GuideHoleView.self, in: window.contentView)
          XCTAssertEqual(holes.count, 1, where_)
          if let hole = holes.first {
            let expected = frameInWindow(place)
            let cut = frameInWindow(hole)
            XCTAssertEqual(cut.minX, expected.minX, accuracy: 0.5, where_)
            XCTAssertEqual(cut.minY, expected.minY, accuracy: 0.5, where_)
            XCTAssertEqual(cut.width, expected.width, accuracy: 0.5, where_)
            XCTAssertEqual(cut.height, expected.height, accuracy: 0.5, where_)
          }
          guide.endWalk()
          window.contentView = nil
          window.close()
        }
      }
    }
  }

  // MARK: The cut-out

  /// The cut-out is the place's frame, wherever the place is and whatever the window's width
  /// and language.
  func testTheCutOutIsTheFrameOfThePlace() {
    assertTheCutOutIsThePlace(widths: [340, 600, 1000])
  }

  /// The same on a window of 1400 points, where the screen holds one.
  func testTheCutOutIsTheFrameOfThePlaceOnAWideWindow() throws {
    try TestEnvironment.requireScreen(width: 1400, height: 640)
    assertTheCutOutIsThePlace(widths: [1400])
  }

  /// A marked place inside another — the search field inside the list of «Траты» — is cut out
  /// as well as the one around it: the outer mark adds to what is inside, never replaces it.
  func testAPlaceInsideAnotherIsCutOutToo() {
    for target in ["inner", "outer"] {
      let inner = Box()
      let outer = Box()
      guide.start(walk([target]))
      let window = show(
        VStack {
          Color.gray.frame(width: 100, height: 24).background(Probe(box: inner)).guideTarget(
            "inner")
          Color.secondary.frame(height: 120)
        }
        .frame(width: 300)
        .background(Probe(box: outer))
        .guideTarget("outer")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .guideOverlay(guide, toolbar: true)
        .appDependencies(dependencies(.english)), width: 600, height: 400)
      let hole = views(GuideHoleView.self, in: window.contentView).first
      let place = target == "inner" ? inner.view : outer.view
      XCTAssertNotNil(hole, target)
      if let hole, let place {
        XCTAssertEqual(frameInWindow(hole).width, frameInWindow(place).width, accuracy: 0.5, target)
        XCTAssertEqual(frameInWindow(hole).minY, frameInWindow(place).minY, accuracy: 0.5, target)
      }
      guide.endWalk()
    }
  }

  /// No walk, no shade and no cut-out: the window as it always is.
  func testWithoutAWalkNothingIsCutOut() {
    let box = Box()
    let window = show(
      root(alignment: .center, language: .russian, box: box), width: 600, height: 400)
    XCTAssertTrue(views(GuideHoleView.self, in: window.contentView).isEmpty)
  }

  // MARK: The words

  /// The words of every step, in Russian and in English, measured as drawn, stay inside windows
  /// of 340 to 1400 points wherever the place is, and beside the place, not over it, when there
  /// is room for them.
  func testTheWordsStayInsideTheWindowAndOffThePlace() {
    let steps =
      GuideCatalog.tutorial.tasks.flatMap(\.hints) + GuideCatalog.whereToClick
      + GuideCatalog.scenarios.flatMap(\.cards).compactMap(GuideWalkthrough.init(card:))
      .map(\.current)
    let sizes = [
      CGSize(width: 340, height: 420), CGSize(width: 600, height: 500),
      CGSize(width: 1000, height: 700), CGSize(width: 1400, height: 900),
    ]
    for language in [AppLanguage.Choice.russian, .english] {
      let deps = dependencies(language)
      for size in sizes {
        let bounds = CGRect(origin: .zero, size: size)
        let width = GuideCaptionPlacement.maxWidth(in: size)
        let holes = [
          CGRect(x: 8, y: 8, width: 180, height: 28),
          CGRect(x: size.width / 2 - 60, y: size.height / 2 - 15, width: 120, height: 30),
          CGRect(x: size.width - 140, y: size.height - 44, width: 130, height: 34),
          CGRect(x: 10, y: size.height - 60, width: size.width - 20, height: 50),
          CGRect(x: 0, y: 0, width: 200, height: size.height),
        ]
        for step in steps {
          let card = NSHostingView(
            rootView: GuideCaptionCard(
              step: step, position: (1, 2), isLast: false, russian: language == .russian,
              next: {}, exit: {}
            )
            .frame(width: width)
            .appDependencies(deps))
          let measured = CGSize(width: width, height: card.fittingSize.height)
          XCTAssertGreaterThan(measured.height, 40, "\(step.target)")
          for hole in holes {
            let estimated = GuideCaptionPlacement.edge(
              for: hole, size: CGSize(width: width, height: GuideCaptionPlacement.estimatedHeight),
              in: bounds)
            let frame = GuideCaptionPlacement.frame(
              size: measured, hole: hole, edge: estimated, in: bounds)
            let inside = bounds.insetBy(
              dx: GuideCaptionPlacement.margin - 0.5, dy: GuideCaptionPlacement.margin - 0.5)
            let where_ = "\(language) \(size) \(hole) \(step.target)"
            XCTAssertTrue(inside.contains(frame) || measured.height > size.height - 24, where_)
            // Placed by its own measured size: off the place whenever a side has room for it.
            let fitted = GuideCaptionPlacement.edge(for: hole, size: measured, in: bounds)
            let roomy = GuideCaptionPlacement.frame(
              size: measured, hole: hole, edge: fitted, in: bounds)
            let hasRoom =
              bounds.maxY - hole.maxY >= measured.height + GuideCaptionPlacement.gap
              + GuideCaptionPlacement.margin
              || hole.minY - bounds.minY >= measured.height + GuideCaptionPlacement.gap
                + GuideCaptionPlacement.margin
            if hasRoom {
              XCTAssertFalse(roomy.intersects(hole), where_)
            }
          }
        }
      }
    }
  }

  /// A place the window does not show: the words in the middle of the window.
  func testWithoutAPlaceTheWordsAreInTheMiddle() throws {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let frame = GuideCaptionPlacement.frame(
      size: CGSize(width: 300, height: 120), hole: nil, edge: nil, in: bounds)
    XCTAssertEqual(frame.midX, bounds.midX, accuracy: 0.5)
    XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.5)
    XCTAssertNil(GuideCaptionPlacement.edge(for: nil, size: frame.size, in: bounds))

    // As laid out on a window, the words of 300 × 120 at its middle.
    let box = Box()
    let window = show(
      GuideCaptionLayout(hole: nil, edge: nil, maxWidth: 300) {
        Color.gray.frame(height: 120).background(Probe(box: box))
      }
      .frame(width: 800, height: 600), width: 800, height: 600)
    let drawn = frameInWindow(try XCTUnwrap(box.view))
    let content = try XCTUnwrap(window.contentView).bounds
    XCTAssertEqual(drawn.midX, content.midX, accuracy: 0.5)
    XCTAssertEqual(drawn.midY, content.midY, accuracy: 0.5)
  }

  /// The guide pointing at a place nobody marked: no cut-out in the window, and the store knows
  /// no root shows it — the words go to the middle and the window stays open to clicks.
  func testAPlaceNotShownHasNoCutOut() {
    let box = Box()
    let window = show(
      root(alignment: .center, language: .english, box: box), width: 600, height: 400)
    guide.start(walk(["nowhere.marked"]))
    settle()
    XCTAssertTrue(views(GuideHoleView.self, in: window.contentView).isEmpty)
    XCTAssertFalse(guide.isShown("nowhere.marked"))
    XCTAssertTrue(guide.isShown(Self.place), "the root told the store what it shows")
  }

  /// A root that goes takes its places with it: the window left is not held for a place no
  /// longer on the screen.
  func testARootThatGoesShowsNothing() {
    let box = Box()
    let window = show(
      root(alignment: .center, language: .english, box: box), width: 600, height: 400)
    XCTAssertTrue(guide.isShown(Self.place))
    // dependencies: a bare colour in place of the root reads nothing from the environment.
    window.contentView = NSHostingView(rootView: Color.clear.frame(width: 600, height: 400))
    settle()
    XCTAssertFalse(guide.isShown(Self.place))
  }

  // MARK: The steps

  /// «Далее» goes through the steps in order and ends the walk after the last; a click on
  /// another place does nothing.
  func testTheStepsGoInOrder() throws {
    guide.start(try XCTUnwrap(walk(["a", "b", "c"])))
    XCTAssertEqual(guide.walk?.current.target, "a")
    guide.clicked("c")
    XCTAssertEqual(guide.walk?.current.target, "a", "a click elsewhere does not move on")
    guide.next()
    XCTAssertEqual(guide.walk?.current.target, "b")
    guide.clicked("b")
    XCTAssertEqual(guide.walk?.current.target, "c")
    guide.next()
    XCTAssertNil(guide.walk, "«Готово» on the last step ends the walk")
  }

  /// A task chosen in «Задания» walks through its own steps, and is left when it is done.
  func testATaskWalksThroughItsSteps() throws {
    let task = try XCTUnwrap(GuideCatalog.tutorial.tasks.first { $0.id == "task.subscription" })
    guide.framedTask = task.id
    XCTAssertEqual(guide.walk?.steps, task.hints)
    XCTAssertEqual(guide.walk?.current.target, GuideTarget.sidebarPlanning)
    guide.clicked(GuideTarget.sidebarPlanning)
    XCTAssertEqual(guide.walk?.current.target, GuideTarget.planningAddPayment)
    guide.framedTask = nil
    XCTAssertNil(guide.walk)
  }

  /// A click landing in the cut-out moves to the next step — after the control under it had the
  /// click; a click outside it does not.
  func testAClickInTheCutOutMovesOn() throws {
    let box = Box()
    guide.start(try XCTUnwrap(walk([Self.place, Self.place])))
    let window = show(
      root(alignment: .center, language: .russian, box: box), width: 600, height: 400)
    let hole = try XCTUnwrap(views(GuideHoleView.self, in: window.contentView).first)
    let frame = frameInWindow(hole)
    func click(at point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)!
    }
    XCTAssertFalse(hole.hears(click(at: CGPoint(x: frame.minX - 20, y: frame.midY))))
    settle(0.1)
    XCTAssertEqual(guide.walk?.index, 0, "a click outside the cut-out")
    XCTAssertTrue(hole.hears(click(at: CGPoint(x: frame.midX, y: frame.midY))))
    settle(0.1)
    XCTAssertEqual(guide.walk?.index, 1, "a click in the cut-out moves on")
    XCTAssertNil(hole.hitTest(CGPoint(x: 5, y: 5)), "the cut-out never takes the click itself")
  }

  /// A step typed into a line does not move on when the line is clicked.
  func testATypedStepWaitsForTheTyping() throws {
    guide.start(try XCTUnwrap(walk([Self.place], click: false)))
    guide.clicked(Self.place)
    XCTAssertNotNil(guide.walk)
  }

  /// Esc leaves the walk, whatever step it is on.
  func testEscLeavesTheWalk() throws {
    guide.start(try XCTUnwrap(walk(["a", "b"])))
    guide.next()
    let window = show(
      Color.clear.frame(width: 300, height: 200).modifier(GuideWhereToClickKeys(guide: guide)),
      width: 300, height: 200)
    let escape = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
      keyCode: 53)!
    XCTAssertTrue(window.performKeyEquivalent(with: escape))
    settle(0.2)
    XCTAssertNil(guide.walk)
  }

  /// «Показать, где» of a card: the cards step aside, the window points at the card's place, and
  /// when the walk ends the cards come back on that card.
  func testACardShowsItsPlaceAndComesBack() throws {
    let scenario = GuideCatalog.firstLaunch
    let index = try XCTUnwrap(scenario.cards.firstIndex { $0.id == "first.line" })
    guide.show(scenario)
    guide.showOnScreen(card: index, of: scenario)
    XCTAssertNil(guide.cards, "the cards step aside")
    XCTAssertEqual(guide.walk?.current.target, GuideTarget.entryLine)
    XCTAssertEqual(guide.walk?.current.text, scenario.cards[index].title)
    guide.endWalk()
    XCTAssertEqual(guide.cards?.id, scenario.id, "the cards are back")
    XCTAssertEqual(guide.takeCardIndex(for: scenario), index, "on the card they left")
    XCTAssertEqual(guide.takeCardIndex(for: scenario), 0, "once")
  }

  /// The buttons and the count of the words, as the owner reads them.
  func testTheWordsSayWhereTheWalkIs() {
    XCTAssertEqual(
      String(format: GuideFlowTests.russian("guide.spot.step", table: "Guide"), 2, 3),
      "Шаг 2 из 3")
    XCTAssertEqual(GuideFlowTests.russian("guide.spot.done", table: "Guide"), "Готово")
    XCTAssertEqual(GuideFlowTests.russian("guide.spot.exit", table: "Guide"), "Выйти · Esc")
    XCTAssertEqual(GuideFlowTests.russian("guide.spot.show", table: "Guide"), "Показать, где")
  }
}
