import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// The cover of a locked window: nothing of the books under it is drawn, read by VoiceOver or
/// reachable by a click or a key — the toolbar included —; the app's password, Touch ID or the
/// password of the Mac take it away (`LockCover`). Every scene of the app wears it at its root (`OhMyMoneyApp`); a sheet or
/// a popover open when the lock comes is covered by `PrivacySheetCovers`.
struct PrivacyCurtain: ViewModifier {
  let lock: PrivacyLock
  let language: AppLanguage

  func body(content: Content) -> some View {
    let locked = lock.isLocked
    content
      .disabled(locked)
      .accessibilityHidden(locked)
      .overlay {
        if locked {
          LockCover(lock: lock, language: language)
        }
      }
      .onAppear {
        lock.startWatching()
        PrivacySheetCovers.update(lock: lock, language: language)
      }
      .onChange(of: locked) { _, _ in PrivacySheetCovers.update(lock: lock, language: language) }
  }
}

extension View {
  /// Covers the window while `lock` is locked.
  func privacyCurtain(_ lock: PrivacyLock, language: AppLanguage) -> some View {
    modifier(PrivacyCurtain(lock: lock, language: language))
  }

  /// The cover of every scene: the lock of the app, in its language.
  @MainActor
  func privacyCurtain(_ environment: AppEnvironment) -> some View {
    privacyCurtain(environment.lock, language: environment.language)
  }
}

/// What a locked window shows: the padlock, «OhMyMoney заблокировано», and the way in — the app's
/// password (Return unlocks) beside «Touch ID», or Touch ID and the password of the Mac alone when
/// the app has no password of its own. After «Забыли пароль?» it asks for a new password.
struct LockCover: View {
  let lock: PrivacyLock
  let language: AppLanguage

  @State private var password = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    ZStack {
      Rectangle().fill(.background)
      VStack(spacing: 14) {
        Image(systemName: "lock.fill")
          .font(.system(size: 44))  // font-fixed: the symbol of the curtain, not text
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: language("privacy.locked.title"))
          .appFont(.title2.weight(.semibold))
        if lock.isChoosingNewPassword {
          newPassword
        } else if lock.hasPassword {
          passwordEntry
        } else {
          Text(verbatim: language("privacy.locked.hint"))
            .foregroundStyle(.secondary)
          touchIDButton(prominent: true)
        }
        if let refusal = lock.lastRefusal, let key = Self.refusalKey(refusal) {
          Label {
            Text(verbatim: language(key))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .foregroundStyle(.red)
          .appFont(.callout)
        }
      }
      .padding(24)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("privacy.cover")
  }

  /// The app's password, «Разблокировать», «Touch ID», «Забыли пароль?», and what went wrong —
  /// with the seconds of a pause counted down.
  private var passwordEntry: some View {
    VStack(spacing: 12) {
      Text(verbatim: language("privacy.locked.passwordHint"))
        .foregroundStyle(.secondary)
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let left = lock.secondsOfPauseLeft(at: lock.currentDate)
        VStack(spacing: 10) {
          SecureField(text: $password) {
            Text(verbatim: language("privacy.password"))
          }
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)
          .focused($fieldFocused)
          .onSubmit(submit)
          .disabled(left > 0 || lock.isCheckingPassword)
          .accessibilityIdentifier("privacy.password")
          HStack(spacing: 10) {
            Button(action: submit) {
              Text(verbatim: language("privacy.unlock"))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(left > 0 || lock.isCheckingPassword || password.isEmpty)
            .accessibilityIdentifier("privacy.unlock.password")
            touchIDButton(prominent: false)
          }
          if left > 0 {
            Label {
              Text(verbatim: language.format("privacy.password.pausedFor", counts: left))
            } icon: {
              Image(systemName: "hourglass")
            }
            .foregroundStyle(.secondary)
            .appFont(.callout)
            .accessibilityIdentifier("privacy.password.pause")
          } else if let key = PrivacyCurtain.problemKey(lock.passwordProblem) {
            Label {
              Text(verbatim: Self.problemText(lock.passwordProblem, key: key, language: language))
            } icon: {
              Image(systemName: "exclamationmark.octagon")
            }
            .foregroundStyle(.red)
            .appFont(.callout)
          }
        }
      }
      Button {
        password = ""
        Task { await lock.forgotPassword(reason: language("privacy.forgot.reason")) }
      } label: {
        Text(verbatim: language("privacy.password.forgot"))
      }
      .buttonStyle(.link)
      .disabled(lock.isAuthenticating)
      .accessibilityIdentifier("privacy.password.forgot")
    }
    .onAppear { fieldFocused = true }
  }

  /// After «Забыли пароль?»: a new password typed twice, or «Позже».
  private var newPassword: some View {
    VStack(spacing: 12) {
      Text(verbatim: language("privacy.password.chooseNew"))
        .foregroundStyle(.secondary)
      LockPasswordFields(
        language: language, problem: lock.passwordProblem, isBusy: lock.isCheckingPassword,
        saveTitleKey: "privacy.password.saveAndUnlock"
      ) { password in
        await lock.chooseNewPassword(password)
      }
      .frame(width: 280)
      Button {
        lock.putOffNewPassword()
      } label: {
        Text(verbatim: language("privacy.password.later"))
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("privacy.password.later")
    }
  }

  /// Touch ID, or the password of the Mac where there is none: the main button when the app has
  /// no password of its own, the second one beside the password otherwise.
  @ViewBuilder
  private func touchIDButton(prominent: Bool) -> some View {
    let button = Button {
      Task { await lock.unlock(reason: language("privacy.unlock.reason")) }
    } label: {
      Label {
        Text(verbatim: language(prominent ? "privacy.unlock" : "privacy.unlock.touchID"))
      } icon: {
        Image(systemName: "touchid")
      }
    }
    .disabled(lock.isAuthenticating)
    if prominent {
      button
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("privacy.unlock")
    } else {
      button
        .buttonStyle(.bordered)
        .accessibilityIdentifier("privacy.unlock.touchID")
    }
  }

  private func submit() {
    guard !password.isEmpty else { return }
    let typed = password
    Task {
      let attempt = await lock.unlock(password: typed)
      if attempt != .ignored { password = "" }
      fieldFocused = true
    }
  }

  /// What the cover says after an attempt that did not pass; nothing after a cancel.
  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "privacy.unlock.failed"
    case .unavailable: "privacy.unlock.unavailable"
    case .cancelled, .passed: nil
    }
  }

  /// The words of a problem of the password, with the attempts left where it has them.
  static func problemText(
    _ problem: PrivacyLock.PasswordProblem?, key: String, language: AppLanguage
  ) -> String {
    if case .wrong(let left) = problem { return language.format(key, counts: left) }
    return language(key)
  }
}

extension PrivacyCurtain {
  /// The key of what went wrong with a password; nothing when nothing did.
  static func problemKey(_ problem: PrivacyLock.PasswordProblem?) -> String? {
    switch problem {
    case .wrong: "privacy.password.wrong"
    case .paused: "privacy.password.paused"
    case .keychain: "privacy.password.keychain"
    case .tooShort: "privacy.password.tooShort"
    case nil: nil
    }
  }
}

/// Sheets, popovers and other windows attached to a window of the app float above the cover of
/// their parent. While the app is locked each gets a cover of its own, an AppKit view on top of
/// its content, and loses it when the app is unlocked. A sheet is modal: the cover of the window
/// under it takes no click and no key while it is up, so the cover of the sheet carries the way
/// in itself — the app's password and «Touch ID или пароль Mac» (`SheetCover`); nothing open
/// while locked can keep the owner out. A sheet that comes while locked is covered as it comes.
@MainActor
enum PrivacySheetCovers {
  #if os(macOS)
    static let identifier = NSUserInterfaceItemIdentifier("privacy.sheetCover")

    /// The lock and the language the covers were made for, while locked.
    private static var lock: PrivacyLock?
    private static var language: AppLanguage?
    private static var windowsWatch: NSObjectProtocol?
    private static var keysWatch: Any?

    static func update(lock: PrivacyLock, language: AppLanguage) {
      if lock.isLocked {
        self.lock = lock
        self.language = language
        coverEverySheet()
        watch()
      } else {
        self.lock = nil
        self.language = nil
        stopWatching()
        for window in NSApp.windows {
          window.contentView?.subviews.filter { $0.identifier == identifier }
            .forEach { $0.removeFromSuperview() }
        }
      }
    }

    /// Covers every sheet, popover and child window that has no cover yet.
    private static func coverEverySheet() {
      guard let lock, let language, lock.isLocked else { return }
      for window in NSApp.windows where window.sheetParent != nil || window.parent != nil {
        guard let content = window.contentView, cover(in: window) == nil else { continue }
        // dependencies: none — the cover reads only the lock and the language it is handed.
        let cover = NSHostingView(rootView: SheetCover(lock: lock, language: language))
        cover.identifier = identifier
        cover.frame = content.bounds
        cover.autoresizingMask = [.width, .height]
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        // The keys go to the cover, not to a field of the sheet hidden under it.
        window.makeFirstResponder(cover)
      }
    }

    private static func cover(in window: NSWindow) -> NSView? {
      window.contentView?.subviews.first { $0.identifier == identifier }
    }

    private static func watch() {
      if windowsWatch == nil {
        windowsWatch = NotificationCenter.default.addObserver(
          forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
          MainActor.assumeIsolated { coverEverySheet() }
        }
      }
      if keysWatch == nil {
        keysWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          let handled = MainActor.assumeIsolated { handles(event) }
          return handled ? nil : event
        }
      }
    }

    private static func stopWatching() {
      if let windowsWatch { NotificationCenter.default.removeObserver(windowsWatch) }
      if let keysWatch { NSEvent.removeMonitor(keysWatch) }
      windowsWatch = nil
      keysWatch = nil
    }

    /// Return, Enter, Esc and Tab in a covered window belong to the cover alone: they would press
    /// the default or the cancel button of the alert under it — «Позже» of the offer of a report,
    /// pressed blind, would spend it — or take the focus there. Return in the field of the
    /// password submits it; anywhere else on the cover it asks Touch ID. Whether the event was
    /// taken.
    static func handles(_ event: NSEvent) -> Bool {
      let guarded: Set<UInt16> = [36, 76, 53, 48]
      guard lock?.isLocked == true, event.type == .keyDown, guarded.contains(event.keyCode),
        let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber),
        let cover = cover(in: window)
      else { return false }
      guard event.keyCode == 36 || event.keyCode == 76 else { return true }
      if let editor = window.firstResponder as? NSTextView, editor.isDescendant(of: cover) {
        editor.keyDown(with: event)
      } else if let lock, let language, !lock.isAuthenticating {
        let reason = language("privacy.unlock.reason")
        Task { await lock.unlock(reason: reason) }
      }
      return true
    }
  #else
    /// iOS sheets sit under the curtain of their scene: there is nothing to cover on top.
    static func update(lock: PrivacyLock, language: AppLanguage) {}
  #endif

  /// The cover of a sheet: the padlock, the app's password when it has one (Return unlocks), and
  /// «Touch ID или пароль Mac». Small enough for an alert of about 260 × 150 pt; «Забыли
  /// пароль?» and a new password stay on the cover of the window — Touch ID or the password of
  /// the Mac open the app from here as well.
  struct SheetCover: View {
    let lock: PrivacyLock
    let language: AppLanguage

    var body: some View {
      ZStack {
        Rectangle().fill(.background)
        Controls(lock: lock, language: language)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("privacy.sheetCover")
    }
  }

  /// What the cover of a sheet offers, at its own size.
  struct Controls: View {
    let lock: PrivacyLock
    let language: AppLanguage

    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
      VStack(spacing: 8) {
        Image(systemName: "lock.fill")
          .font(.system(size: 18))  // font-fixed: the symbol of the curtain, not text
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        if lock.hasPassword, !lock.isChoosingNewPassword {
          passwordEntry
        }
        Button {
          Task { await lock.unlock(reason: language("privacy.unlock.reason")) }
        } label: {
          Label {
            Text(verbatim: language("privacy.unlock.touchID"))
          } icon: {
            Image(systemName: "touchid")
          }
        }
        .controlSize(.small)
        .disabled(lock.isAuthenticating)
        .accessibilityIdentifier("privacy.sheetCover.touchID")
        if let refusal = lock.lastRefusal, let key = LockCover.refusalKey(refusal) {
          caption(language(key))
        }
      }
      .multilineTextAlignment(.center)
      .padding(10)
    }

    /// The field of the app's password, and the pause or what went wrong under it.
    private var passwordEntry: some View {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let left = lock.secondsOfPauseLeft(at: lock.currentDate)
        VStack(spacing: 4) {
          SecureField(text: $password) {
            Text(verbatim: language("privacy.password"))
          }
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .frame(maxWidth: 200)
          .focused($fieldFocused)
          .onSubmit(submit)
          .disabled(left > 0 || lock.isCheckingPassword)
          .accessibilityIdentifier("privacy.sheetCover.password")
          if left > 0 {
            caption(language.format("privacy.password.pausedFor", counts: left), problem: false)
          } else if let key = PrivacyCurtain.problemKey(lock.passwordProblem) {
            caption(LockCover.problemText(lock.passwordProblem, key: key, language: language))
          }
        }
      }
      .onAppear { fieldFocused = true }
    }

    private func caption(_ text: String, problem: Bool = true) -> some View {
      Text(verbatim: text)
        .appFont(.caption)
        .foregroundStyle(problem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
      guard !password.isEmpty else { return }
      let typed = password
      Task {
        let attempt = await lock.unlock(password: typed)
        if attempt != .ignored { password = "" }
        fieldFocused = true
      }
    }
  }
}
