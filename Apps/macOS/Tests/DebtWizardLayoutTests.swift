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

  func testEveryStepFitsItsSheet() async throws {
    let host = try await EntryHost(opensDetails: false, width: 400)
    self.host = host
    let deps = AppDependencies(
      environment: host.environment, store: host.store, compute: ComputeStore(calendar: .system))
    let today = host.environment.today
    for language in [AppLanguage.Choice.russian, .english] {
      host.environment.language.choice = language
      for width in [CGFloat(340), 520] {
        for kind in [DebtWizardKind.loan, .instalments, .pledge] {
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
            host.settle(0.3)
            let content = try XCTUnwrap(window.contentView)
            let place = "\(language) \(width) \(kind) \(step)"
            // A busy Mac lays the step out later than the pause above: the fields are read once
            // their frames stop moving (up to ten seconds), so the test measures the layout the
            // sheet settles in, not one on its way there.
            func shown() -> [CGRect] {
              content.layoutSubtreeIfNeeded()
              return controls(in: content).filter { !$0.isHidden && $0.frame.width > 0 }
                .map { $0.convert($0.bounds, to: nil) }
            }
            var last = shown()
            var same = 0
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
              host.settle(0.1)
              let now = shown()
              same = now == last && !content.needsLayout ? same + 1 : 0
              if same >= 3 { break }
              last = now
            }
            let found = controls(in: content).filter { !$0.isHidden && $0.frame.width > 0 }
            // The kind and the preview are SwiftUI's own; the fields of the other steps are AppKit's.
            if step == .amount || step == .payments {
              XCTAssertFalse(found.isEmpty, "the step has fields: \(place)")
            }
            for control in found {
              let frame = control.convert(control.bounds, to: nil)
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
