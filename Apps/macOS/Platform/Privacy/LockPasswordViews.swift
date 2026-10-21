import SwiftUI

/// A new password typed twice: «Пароль» and «Ещё раз», what is wrong with them in words, and the
/// button that keeps it (Return in either field does the same). Shared by the cover after
/// «Забыли пароль?» and by the sheet of Settings.
struct LockPasswordFields: View {
  let language: AppLanguage
  /// What the lock said about the last attempt to keep a password.
  let problem: PrivacyLock.PasswordProblem?
  /// The record is being made: the fields wait.
  let isBusy: Bool
  let saveTitleKey: String
  let save: (String) async -> Void

  @State private var first = ""
  @State private var second = ""
  @State private var issue: LockPassword.Issue?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SecureField(text: $first) {
        Text(verbatim: language("privacy.password.new"))
      }
      .onSubmit(submit)
      .accessibilityIdentifier("privacy.password.new")
      SecureField(text: $second) {
        Text(verbatim: language("privacy.password.repeat"))
      }
      .onSubmit(submit)
      .accessibilityIdentifier("privacy.password.repeat")
      if let key = Self.issueKey(issue) ?? PrivacyCurtain.problemKey(problem) {
        Label {
          Text(verbatim: language(key))
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
        .appFont(.callout)
      } else {
        Text(verbatim: language("privacy.password.rule"))
          .foregroundStyle(.secondary)
          .appFont(.callout)
      }
      HStack {
        Spacer()
        if isBusy { ProgressView().controlSize(.small) }
        Button(action: submit) {
          Text(verbatim: language(saveTitleKey))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isBusy || first.isEmpty)
        .accessibilityIdentifier("privacy.password.save")
      }
    }
    .disabled(isBusy)
  }

  private func submit() {
    guard !isBusy else { return }
    if let found = LockPassword.issue(first, repeated: second) {
      issue = found
      return
    }
    issue = nil
    let password = first
    Task { await save(password) }
  }

  /// What a new password typed twice is told.
  static func issueKey(_ issue: LockPassword.Issue?) -> String? {
    switch issue {
    case .tooShort: "privacy.password.tooShort"
    case .mismatch: "privacy.password.mismatch"
    case nil: nil
    }
  }
}

/// The sheet of Settings that chooses the app's password: when the lock is turned on, and to
/// change or set it later.
struct LockPasswordSheet: View {
  enum Purpose: String, Identifiable {
    /// The lock is being turned on; Touch ID has passed.
    case first
    /// The lock is on: a new password replaces the old one, or the first one is set.
    case change

    var id: String { rawValue }
  }

  let purpose: Purpose
  let lock: PrivacyLock
  let language: AppLanguage
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        verbatim: language(
          purpose == .first ? "privacy.password.title" : "privacy.password.change")
      )
      .appFont(.headline)
      Text(verbatim: language("privacy.password.explain"))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LockPasswordFields(
        language: language, problem: lock.passwordProblem, isBusy: lock.isCheckingPassword,
        saveTitleKey: purpose == .first ? "privacy.password.turnOn" : "privacy.password.save"
      ) { password in
        let kept =
          purpose == .first
          ? await lock.enable(password: password) : await lock.setPassword(password)
        if kept { done() }
      }
      HStack {
        Button {
          // Cancel wins over a record still being made: it is not kept.
          if purpose == .first { lock.cancelEnabling() } else { lock.cancelPasswordChange() }
          done()
        } label: {
          Text(verbatim: language("privacy.password.cancel"))
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}
