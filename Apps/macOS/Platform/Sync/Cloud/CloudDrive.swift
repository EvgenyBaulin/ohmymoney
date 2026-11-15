import AppCore
import AppDatabase
import Foundation

/// One field of the form of a drive that is entered, not signed in to.
struct CloudCredentialField: Identifiable, Equatable, Sendable {
  var id: String
  var labelKey: String
  var isSecret: Bool
}

/// The six cloud drives of the exchange. Settings lists every case; a drive that signs in
/// through a page of its service (`oauth`) can be connected only when the application id is in
/// `CloudDriveKeys`, a drive that takes what the owner types (`fields`) always can.
/// Strings are in the `CloudDrives` catalog.
enum CloudDrive: String, CaseIterable, Sendable, Identifiable {
  case yandexDisk = "yandex"
  case dropbox
  case oneDrive = "onedrive"
  case googleDrive = "google"
  case mailRuCloud = "mailru"
  case supabase

  static let table = "CloudDrives"
  static let unavailableKey = "cloud.connect.unavailable"

  var id: String { rawValue }
  var nameKey: String { "cloud.drive.\(rawValue)" }

  /// The sign-in of a drive that has a page of its own; `nil` for a drive with a form.
  var oauth: CloudOAuthConfig? {
    switch self {
    case .yandexDisk: YandexDiskBackend.config
    case .dropbox: DropboxBackend.config
    case .oneDrive: OneDriveBackend.config
    case .googleDrive: GoogleDriveConfig.oauth()
    case .mailRuCloud, .supabase: nil
    }
  }

  /// What the owner types for a drive without a sign-in page.
  var fields: [CloudCredentialField] {
    switch self {
    case .mailRuCloud:
      [
        CloudCredentialField(id: "login", labelKey: "cloud.mailru.login", isSecret: false),
        CloudCredentialField(id: "password", labelKey: "cloud.mailru.appPassword", isSecret: true),
      ]
    case .supabase:
      [
        CloudCredentialField(id: "url", labelKey: "cloud.supabase.url", isSecret: false),
        CloudCredentialField(id: "key", labelKey: "cloud.supabase.key", isSecret: true),
      ]
    default: []
    }
  }

  var isConnectable: Bool { oauth?.isConfigured ?? true }

  /// Why "Connect" is unavailable, or `nil` when it is available.
  var unavailableReasonKey: String? { isConnectable ? nil : Self.unavailableKey }
}

enum CloudConnectError: Error, Equatable {
  /// A field is empty or malformed (an address that is not https, a login without `@`).
  case invalidInput
  case unavailable
  case keychain
}

/// Which drive this device exchanges through; kept in the settings of the device. The folder
/// picked in Settings and the drive exclude each other.
enum CloudDriveSelection {
  static let key = "sync.cloud.drive"

  static func selected(in defaults: UserDefaults = .standard) -> CloudDrive? {
    defaults.string(forKey: key).flatMap(CloudDrive.init(rawValue:))
  }

  static func select(_ drive: CloudDrive?, in defaults: UserDefaults = .standard) {
    if let drive {
      defaults.set(drive.rawValue, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

/// Connects, disconnects and opens the drives: tokens and passwords go to the keychain of this
/// device only. Everything that touches the network is built from `http` and `retry`, so a test
/// puts a stub server underneath.
struct CloudDriveConnection: Sendable {
  var credentials: any CloudCredentialStoring = KeychainCloudCredentialStore()
  var tokens: @Sendable (CloudDrive) -> any CloudTokenStoring = {
    KeychainCloudTokenStore(providerId: $0.rawValue)
  }
  var http: any CloudHTTPTransporting = URLSessionCloudHTTP()
  var retry = CloudRetryPolicy()

  func authorizer(for drive: CloudDrive) -> CloudAuthorizer? {
    drive.oauth.map { CloudAuthorizer(config: $0, store: tokens(drive), http: http, retry: retry) }
  }

  func isConnected(_ drive: CloudDrive) -> Bool {
    switch drive {
    case .mailRuCloud: MailRuCloudConfig.load(from: credentials) != nil
    case .supabase: SupabaseConfig.load(from: credentials) != nil
    default: authorizer(for: drive)?.isSignedIn ?? false
    }
  }

  /// Saves what was typed for a drive with a form. Nothing is saved when it does not parse.
  func connect(_ drive: CloudDrive, values: [String: String]) throws {
    do {
      switch drive {
      case .mailRuCloud:
        guard
          let config = MailRuCloudConfig(
            login: values["login"] ?? "", appPassword: values["password"] ?? "")
        else { throw CloudConnectError.invalidInput }
        try config.save(to: credentials)
      case .supabase:
        guard let config = SupabaseConfig(url: values["url"] ?? "", key: values["key"] ?? "")
        else { throw CloudConnectError.invalidInput }
        try config.save(to: credentials)
      default:
        throw CloudConnectError.unavailable
      }
    } catch let error as CloudConnectError {
      throw error
    } catch {
      throw CloudConnectError.keychain
    }
  }

  /// Signs in on the page of the drive and stores the tokens.
  @MainActor
  func signIn(_ drive: CloudDrive) async throws {
    guard let config = drive.oauth, config.isConfigured, let authorizer = authorizer(for: drive)
    else { throw CloudSignInError.notConfigured }
    try await CloudOAuthFlow.signIn(config: config, authorizer: authorizer)
  }

  func disconnect(_ drive: CloudDrive) {
    switch drive {
    case .mailRuCloud:
      credentials.remove(account: MailRuCloudConfig.loginAccount)
      credentials.remove(account: MailRuCloudConfig.passwordAccount)
    case .supabase:
      credentials.remove(account: SupabaseConfig.urlAccount)
      credentials.remove(account: SupabaseConfig.keyAccount)
    default:
      authorizer(for: drive)?.disconnect()
    }
  }

  /// The transport of a connected drive, `nil` when nobody has connected it.
  func makeTransport(_ drive: CloudDrive) -> (any ExchangeFileTransport)? {
    switch drive {
    case .mailRuCloud:
      guard let config = MailRuCloudConfig.load(from: credentials) else { return nil }
      return MailRuCloudTransport(
        client: MailRuCloudTransport.client(config: config, http: http, retry: retry))
    case .supabase:
      guard let config = SupabaseConfig.load(from: credentials) else { return nil }
      return SupabaseStorageTransport(
        config: config,
        client: SupabaseStorageTransport.client(config: config, http: http, retry: retry))
    default:
      guard let authorizer = authorizer(for: drive), authorizer.isSignedIn else { return nil }
      let client = CloudHTTPClient(http: http, authorizer: authorizer, retry: retry)
      switch drive {
      case .yandexDisk: return CloudFileTransport(backend: YandexDiskBackend(client: client))
      case .dropbox: return CloudFileTransport(backend: DropboxBackend(client: client))
      case .oneDrive: return CloudFileTransport(backend: OneDriveBackend(client: client))
      default: return GoogleDriveTransport(client: client)
      }
    }
  }

  func makeFolder(_ drive: CloudDrive) -> TransportExchangeFolder? {
    makeTransport(drive).map { TransportExchangeFolder(transport: $0) }
  }
}
