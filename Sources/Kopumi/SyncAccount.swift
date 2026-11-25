// Sync account: keys and pairing link, base64url, Keychain storage. Protocol: protocol/SYNC.md
import CryptoKit
import Foundation
import Security

/// Everything a device needs to join an account; it *is* the pairing link.
struct SyncAccount: Equatable {
  let relay: URL
  let id: String
  let key: Data  // 32 bytes, never sent to the relay

  static func create(relay: URL) -> SyncAccount {
    let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    return SyncAccount(relay: relay, id: UUID().uuidString.lowercased(), key: key)
  }

  init(relay: URL, id: String, key: Data) {
    self.relay = relay
    self.id = id
    self.key = key
  }

  init?(link: String) {
    guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
      c.scheme == "kopumi", c.host == "pair",
      let r = c.queryItems?.first(where: { $0.name == "r" })?.value, let relay = URL(string: r),
      relay.scheme == "https" || relay.scheme == "http",
      let a = c.queryItems?.first(where: { $0.name == "a" })?.value, UUID(uuidString: a) != nil,
      let k = c.queryItems?.first(where: { $0.name == "k" })?.value, let key = base64url(k),
      key.count == 32
    else { return nil }
    self.init(relay: relay, id: a.lowercased(), key: key)
  }

  var link: String {
    var c = URLComponents()
    c.scheme = "kopumi"
    c.host = "pair"
    c.queryItems = [
      .init(name: "r", value: relay.absoluteString), .init(name: "a", value: id),
      .init(name: "k", value: base64url(key)),
    ]
    // URLComponents leaves ":" and "/" unescaped in queries; escape them like encodeURIComponent.
    c.percentEncodedQuery = c.percentEncodedQuery?
      .replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F")
    return c.string!
  }

  var encKey: SymmetricKey { derive("kopumi-enc-v1") }
  var authToken: String {
    derive("kopumi-auth-v1").withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
  }
  var base: URL { relay.appending(path: "v1/a/\(id)") }

  private func derive(_ info: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key), salt: Data(), info: Data(info.utf8),
      outputByteCount: 32)
  }

  func seal(_ plaintext: Data, id: String) throws -> String {
    try AES.GCM.seal(plaintext, using: encKey, authenticating: Data(id.utf8)).combined!
      .base64EncodedString()
  }

  func open(_ sealed: String, id: String) throws -> Data {
    guard let data = Data(base64Encoded: sealed) else { throw SyncError("bad base64") }
    return try AES.GCM.open(
      AES.GCM.SealedBox(combined: data), using: encKey, authenticating: Data(id.utf8))
  }
}

func base64url(_ d: Data) -> String {
  d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func base64url(_ s: String) -> Data? {
  var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  b += String(repeating: "=", count: (4 - b.count % 4) % 4)
  return Data(base64Encoded: b)
}

struct SyncError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// The pairing link lives in the login Keychain.
enum SyncKeychain {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.daliys.kopumi.sync", kSecAttrAccount as String: "account",
    ]
  }

  static func load() -> SyncAccount? {
    var q = query
    q[kSecReturnData as String] = true
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
      let link = String(data: d, encoding: .utf8)
    else { return nil }
    return SyncAccount(link: link)
  }

  static func save(_ a: SyncAccount?) {
    SecItemDelete(query as CFDictionary)
    guard let a else { return }
    var q = query
    q[kSecValueData as String] = Data(a.link.utf8)
    SecItemAdd(q as CFDictionary, nil)
  }
}
