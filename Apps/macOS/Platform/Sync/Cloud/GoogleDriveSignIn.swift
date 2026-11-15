import AuthenticationServices
import Foundation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The system sign-in sheet of Google (ASWebAuthenticationSession, PKCE). It returns the
/// authorization code; the tokens are then fetched by `GoogleDriveSession`.
@MainActor
final class GoogleDriveSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  enum Failure: Error { case notConfigured, cancelled, rejected }

  private var running: ASWebAuthenticationSession?

  func signIn(session: GoogleDriveSession) async throws {
    guard GoogleDriveConfig.isConfigured else { throw Failure.notConfigured }
    let pkce = PKCEPair.make()
    let state = PKCEPair.random()
    guard let url = session.authorizationURL(pkce: pkce, state: state) else {
      throw Failure.rejected
    }
    let scheme = GoogleDriveConfig.redirectScheme(clientID: GoogleDriveConfig.clientID)
    let callback: URL = try await withCheckedThrowingContinuation { continuation in
      let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
        if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: Failure.cancelled) }
      }
      auth.presentationContextProvider = self
      running = auth
      if !auth.start() { continuation.resume(throwing: Failure.rejected) }
    }
    running = nil
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard items.first(where: { $0.name == "state" })?.value == state,
      let code = items.first(where: { $0.name == "code" })?.value
    else { throw Failure.rejected }
    try await Task.detached { try session.completeSignIn(code: code, pkce: pkce) }.value
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if canImport(AppKit)
      return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    #else
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      return scene?.keyWindow ?? ASPresentationAnchor()
    #endif
  }
}
