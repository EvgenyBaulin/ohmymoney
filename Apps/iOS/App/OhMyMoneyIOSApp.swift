import AppCore
import SwiftUI

@main
struct OhMyMoneyIOSApp: App {
  @State private var session = AppSession()
  @State private var lock = AppLock()

  var body: some Scene {
    WindowGroup {
      ShieldedRoot(session: session, lock: lock)
    }
  }
}

/// The root of the one scene: the app under it, and over it what must hide the books — the
/// lock until the proof is given, and the plain cover whenever the app is not in front, so the
/// picture the system takes for the app switcher shows nothing.
struct ShieldedRoot: View {
  let session: AppSession
  let lock: AppLock
  @Environment(\.scenePhase) private var phase

  var body: some View {
    let environment = session.deps.environment
    ZStack {
      PhoneRoot(deps: session.deps, session: session, lock: lock)
        // Made again at every lock: no sheet or pushed screen of the books stays over the cover.
        .id("\(session.generation)-\(lock.lockCount)")
        .disabled(lock.isLocked)
        .accessibilityHidden(lock.isLocked)
      if lock.isLocked {
        LockScreen(lock: lock, language: environment.language)
      } else if phase != .active {
        SwitcherCover()
      }
    }
    .appDependencies(session.deps)
    // The questions the shared screens raise by themselves wait while the cover is up.
    .onChange(of: lock.isLocked, initial: true) { _, locked in
      session.deps.environment.lock.hostCovers = locked
    }
    .onChange(of: session.generation) { _, _ in
      session.deps.environment.lock.hostCovers = lock.isLocked
    }
    .task {
      await session.start()
      if lock.isLocked { await tryUnlock() }
    }
    .onChange(of: phase) { _, now in
      switch now {
      case .background: lock.didEnterBackground()
      case .active:
        lock.didBecomeActive()
        if lock.isLocked { Task { await tryUnlock() } }
      default: break
      }
    }
  }

  private func tryUnlock() async {
    await lock.unlock(
      reason: session.deps.environment.language("phone.lock.reason", table: "Phone"))
  }
}

/// Nothing of the books: what the app switcher gets.
struct SwitcherCover: View {
  var body: some View {
    ZStack {
      Rectangle().fill(.background)
      Image(systemName: "lock.fill")
        .font(.system(size: 44))  // font-fixed: the symbol of the cover, not text
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .ignoresSafeArea()
  }
}

/// The lock: the padlock and the way in. Face ID is asked by itself when the app opens; the
/// button asks again after a refusal.
struct LockScreen: View {
  let lock: AppLock
  let language: AppLanguage

  var body: some View {
    ZStack {
      Rectangle().fill(.background).ignoresSafeArea()
      VStack(spacing: 14) {
        Image(systemName: "lock.fill")
          .font(.system(size: 44))  // font-fixed: the symbol of the cover, not text
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: language("privacy.locked.title"))
          .appFont(.title2.weight(.semibold))
        if let refusal = lock.lastRefusal, let key = Self.refusalKey(refusal) {
          Label {
            Text(verbatim: language(key, table: "Phone"))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .appFont(.callout)
          .foregroundStyle(.secondary)
        }
        Button {
          Task {
            await lock.unlock(reason: language("phone.lock.reason", table: "Phone"))
          }
        } label: {
          Text(verbatim: language("phone.lock.unlock", table: "Phone"))
        }
        .buttonStyle(.borderedProminent)
        .disabled(lock.isAuthenticating)
      }
      .padding(24)
    }
  }

  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "phone.lock.failed"
    case .unavailable: "phone.lock.unavailable"
    case .cancelled, .passed: nil
    }
  }
}
