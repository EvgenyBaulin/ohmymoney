import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Новый долг» in a window: every step of the wizard, in Russian and English, keeps its
/// controls inside a sheet as narrow as 340 pt and as wide as its own 520.
@MainActor
final class DebtWizardLayoutTests: XCTestCase {
  private var host: EntryHost?
  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    host?.close()
  }

  private func controls(in view: NSView) -> [NSControl] {
    view.subviews.flatMap { sub -> [NSControl] in
      (sub as? NSControl).map { [$0] + controls(in: sub) } ?? controls(in: sub)
    }
  }

  private struct ViewLayout: Equatable {
    let id: ObjectIdentifier
    let frame: CGRect
    let bounds: CGRect
    let hidden: Bool
  }

  /// Yields to SwiftUI between passes and waits for the whole view tree to stop changing.
  /// Stable control frames alone can belong to an incomplete layout with pending ancestors.
  private func settledFrames(in window: NSWindow, requiresControls: Bool) async throws -> [CGRect]?
  {
    let content = try XCTUnwrap(window.contentView)
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(20)
    var previous: [ViewLayout] = []
    var stablePasses = 0
    while clock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      content.layoutSubtreeIfNeeded()
      window.displayIfNeeded()

      var snapshot: [ViewLayout] = []
      var clean = true
      func record(_ view: NSView) {
        snapshot.append(
          ViewLayout(
            id: ObjectIdentifier(view), frame: view.frame, bounds: view.bounds,
            hidden: view.isHidden))
        if !view.isHiddenOrHasHiddenAncestor {
          clean = clean && !view.needsLayout && !view.needsUpdateConstraints
        }
        for child in view.subviews { record(child) }
      }
      record(content)
      let frames = controls(in: content).filter { !$0.isHidden && $0.frame.width > 0 }
        .map { $0.convert($0.bounds, to: nil) }
      let ready = !requiresControls || !frames.isEmpty
      stablePasses = ready && clean && snapshot == previous ? stablePasses + 1 : 0
      if stablePasses >= 10 { return frames }
      previous = snapshot
    }
    return nil
  }

  func testEveryStepFitsItsSheet() async throws {
    self.executionTimeAllowance = 240
    let host = try await EntryHost(opensDetails: false, width: 400)
    self.host = host
    let deps = AppDependencies(
      environment: host.environment, store: host.store, compute: ComputeStore(calendar: .system))
    let today = host.environment.today
    for language in [AppLanguage.Choice.russian, .english] {
      host.environment.language.choice = language
      for width in [CGFloat(340), 520] {
        for kind in [DebtWizardKind.loan, .instalments, .split, .pledge] {
          for step in DebtWizardModel.Step.allCases {
            var model = DebtWizardModel(today: today, currency: .rub)
            model.choose(kind, today: today, language: host.environment.language)
            model.name = "Long name of a debt"
            model.amount = AmountE4(whole: 120_000)
            model.rateText = "12"
            model.monthly = AmountE4(whole: 10_000)
            model.step = step
            let window = NSWindow(
              contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.contentView = NSHostingView(
              rootView: DebtWizard(model: model).frame(width: width, height: 900)
                .appDependencies(deps))
            window.makeKeyAndOrderFront(nil)
            let place = "\(language) \(width) \(kind) \(step)"
            let settled = try await settledFrames(
              in: window, requiresControls: step == .amount || step == .payments)
            let frames = try XCTUnwrap(settled, "the sheet layout did not settle: \(place)")
            // The kind and the preview are SwiftUI's own; the fields of the other steps are AppKit's.
            if step == .amount || step == .payments {
              XCTAssertFalse(frames.isEmpty, "the step has fields: \(place)")
            }
            for frame in frames {
              XCTAssertGreaterThanOrEqual(frame.minX, 0, "past the left edge: \(place)")
              XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "past the right edge: \(place)")
            }
            window.contentView = nil
            window.close()
          }
        }
      }
    }
  }
}
