import Foundation
import Testing

@testable import CoreArchive

/// A Focus filter switches «Скрыть суммы» only: on with the Focus, back off with its end —
/// unless the owner had hidden the amounts before it began.
@Suite("A Focus hides the amounts and gives them back")
struct FocusAmountsTests {
  @Test func theFocusHidesAndItsEndShows() {
    var focus = FocusAmounts()
    let started = focus.apply(focusHides: true, hiddenNow: false)
    #expect(started)
    #expect(focus.focusHid)
    let ended = focus.apply(focusHides: false, hiddenNow: true)
    #expect(!ended)
    #expect(!focus.focusHid)
  }

  /// Hidden by hand before the Focus: they stay hidden when it ends.
  @Test func amountsHiddenByHandStayHidden() {
    var focus = FocusAmounts()
    let started = focus.apply(focusHides: true, hiddenNow: true)
    #expect(started)
    #expect(!focus.focusHid)
    let ended = focus.apply(focusHides: false, hiddenNow: true)
    #expect(ended)
  }

  /// A Focus that does not ask to hide changes nothing.
  @Test func aFocusThatDoesNotAskChangesNothing() {
    var focus = FocusAmounts()
    let shown = focus.apply(focusHides: false, hiddenNow: false)
    #expect(!shown)
    let hidden = focus.apply(focusHides: false, hiddenNow: true)
    #expect(hidden)
  }

  /// Shown by hand during the Focus: its end does not hide them again or touch them.
  @Test func theOwnerTakesTheSwitchBack() {
    var focus = FocusAmounts()
    _ = focus.apply(focusHides: true, hiddenNow: false)
    focus.ownerChanged()
    let ended = focus.apply(focusHides: false, hiddenNow: false)
    #expect(!ended)
  }

  @Test func theStateTravelsAsJSON() throws {
    var focus = FocusAmounts()
    _ = focus.apply(focusHides: true, hiddenNow: false)
    let data = try JSONEncoder().encode(focus)
    #expect(try JSONDecoder().decode(FocusAmounts.self, from: data) == focus)
  }
}
