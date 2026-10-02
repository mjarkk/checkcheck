import Foundation
import Security

/// The app's server URL and token, copied into a keychain item the widget
/// extension can read too. Compiled into both targets.
struct WidgetConnection: Codable, Equatable {
  let server: String
  let token: String

  /// Also the keychain access group: app group names double as one.
  static let appGroup = "group.nl.mkopenga.checkcheck"

  private static let service = "nl.mkopenga.checkcheck.connection"
  private static let account = "connection"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: appGroup,
    ]
  }

  /// Nil when the app isn't connected, or the keychain is locked because the
  /// phone hasn't been unlocked since it started.
  static func load() -> WidgetConnection? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(WidgetConnection.self, from: data)
  }

  /// Throws the `OSStatus` of a failed keychain write as an `NSError`.
  func save() throws {
    let data = try JSONEncoder().encode(self)
    let update: [String: Any] = [
      kSecValueData as String: data,
      // The widget reloads while the phone is locked.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(Self.query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(Self.query.merging(update) { $1 } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  static func clear() {
    SecItemDelete(query as CFDictionary)
  }
}
