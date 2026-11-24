// Sync self-checks: shared protocol vectors, merge rules between two stores (part of --check),
// and `Kopumi --check-sync <relay URL>` for a real round trip through a relay.
import CryptoKit
import Foundation

private let vectorsDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "protocol/vectors")

private func vector<T: Decodable>(_ name: String, _: T.Type) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(contentsOf: vectorsDir.appending(path: name)))
}

private struct CryptoVector: Decodable {
  struct Rec: Decodable { let id, plaintext, sealed: String }
  struct Pair: Decodable { let link, relay, accountId: String }
  let accountKeyHex, encKeyHex, authToken: String
  let record: Rec
  let pairing: Pair
}

private struct ClassifyVector: Decodable {
  struct Kind: Decodable { let text, kind: String }
  let kinds: [Kind]
  let sensitive, notSensitive: [String]
}

private func hex(_ s: String) -> Data {
  Data(
    stride(from: 0, to: s.count, by: 2).map { i in
      UInt8(s.dropFirst(i).prefix(2), radix: 16)!
    })
}

@MainActor
func checkSync() throws {
  try checkSyncVectors()
  try checkSyncMerge()
}

@MainActor
private func checkSyncVectors() throws {
  for v in try vector("hash.json", [[String: String]].self) {
    let got = Watcher.hash(v["prefix"]!, Data(v["text"]!.utf8))
    precondition(got == v["hash"], "hash vector \(v["text"]!.debugDescription)")
  }
  let c = try vector("classify.json", ClassifyVector.self)
  for k in c.kinds {
    precondition(classify(k.text).kind.rawValue == k.kind, "classify vector \(k.text)")
  }
  for s in c.sensitive { precondition(isSensitive(s), "sensitive vector \(s)") }
  for s in c.notSensitive { precondition(!isSensitive(s), "not-sensitive vector \(s)") }

  let v = try vector("crypto.json", CryptoVector.self)
  let a = SyncAccount(
    relay: URL(string: v.pairing.relay)!, id: v.pairing.accountId, key: hex(v.accountKeyHex))
  precondition(
    a.encKey.withUnsafeBytes { Data($0) } == hex(v.encKeyHex), "HKDF enc key")
  precondition(a.authToken == v.authToken, "HKDF auth token")
  precondition(a.link == v.pairing.link, "pairing link \(a.link)")
  precondition(SyncAccount(link: v.pairing.link) == a, "pairing link parse")
  precondition(SyncAccount(link: "kopumi://pair?r=x&a=nope&k=AA") == nil, "bad link")
  let opened = try a.open(v.record.sealed, id: v.record.id)
  precondition(String(data: opened, encoding: .utf8) == v.record.plaintext, "AES-GCM open")
  precondition((try? a.open(v.record.sealed, id: "other")) == nil, "AAD binds the id")
  let r = try JSONDecoder().decode(SyncRecord.self, from: opened)
  precondition(r.kind == "url" && r.meta == #"{"host":"example.com"}"#, "record decode")
  let again = try a.open(try a.seal(Data("x".utf8), id: "i"), id: "i")
  precondition(again == Data("x".utf8), "seal roundtrip")
}

@MainActor
private func withStores(_ body: (Store, Store) throws -> Void) throws {
  let dir = NSTemporaryDirectory() + "kopumi-sync-\(UUID())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try body(
    try Store(path: dir + "/a.sqlite", deviceId: "dev-a"),
    try Store(path: dir + "/b.sqlite", deviceId: "dev-b"))
}

/// Simulated relay: everything pending on `from` is applied on `to`.
@MainActor
private func send(_ from: Store, _ to: Store, now: Int64) throws {
  let batch = try from.pendingSync(limit: 1000)
  for r in batch { try to.applyRemote(r, now: now) }
  try from.markSynced(batch)
}

@MainActor
private func clip(_ t: String, secret: Bool = false) -> NewClip {
  NewClip(
    kind: .text, text: t, contentHash: Watcher.hash("text", Data(t.utf8)), sensitive: secret)
}

@MainActor
private func checkSyncMerge() throws {
  try withStores { a, b in
    let id = try a.upsert(clip("hello"), now: 10)
    try a.upsert(clip("sk-secret-never-syncs", secret: true), now: 11)
    try send(a, b, now: 12)
    let ok100 = try b.recent(limit: 9).map(\.id) == [id]
    precondition(ok100, "B received only the non-secret")
    let ok102 = try b.pendingSync(limit: 9).isEmpty
    precondition(ok102, "applied records aren't pushed back")

    try b.touch(id: id, now: 20)
    let newer = try b.pendingSync(limit: 9)
    try send(b, a, now: 21)
    let ok108 = try a.recent(limit: 9).first?.lastUsedAt == 20
    precondition(ok108, "touch synced")
    var stale = newer[0]
    stale.updatedAt = 15
    let ok112 = try a.applyRemote(stale)
    precondition(!ok112, "older version loses")

    try a.clearHistory(now: 30)
    try send(a, b, now: 31)
    let ok117 = try b.recent(limit: 9).isEmpty
    precondition(ok117, "delete synced")

    // Same text copied on both devices before they synced: both keep the smaller id.
    let ia = try a.upsert(clip("same"), now: 40)
    let ib = try b.upsert(clip("same"), now: 41)
    try send(a, b, now: 42)
    try send(b, a, now: 43)
    try send(a, b, now: 44)
    try send(b, a, now: 45)
    let keep = min(ia, ib)
    let ok128 = try a.recent(limit: 9).map(\.id) == [keep]
    precondition(ok128, "A twin")
    let ok130 = try b.recent(limit: 9).map(\.id) == [keep]
    precondition(ok130, "B twin")

    // Retention is per device: pruning on A must not delete on B.
    try a.upsert(clip("newest"), now: 50)
    try send(a, b, now: 51)
    try a.prune(maxItems: 1, now: 52)
    let prunedPushes = try a.pendingSync(limit: 9)
    precondition(prunedPushes.isEmpty, "retention prune stays local")
    let bCount = try b.recent(limit: 9).count
    precondition(bCount == 2, "B keeps what A pruned")
  }
}

/// Two devices through a real relay: copy, receive, delete. Uses a throwaway account.
@MainActor
func checkSyncRelay(_ relay: URL) async throws {
  let account = SyncAccount.create(relay: relay)
  let dir = NSTemporaryDirectory() + "kopumi-relay-\(UUID())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  let a = Sync(store: try Store(path: dir + "/a.sqlite", deviceId: "dev-a"), account: account)
  let b = Sync(store: try Store(path: dir + "/b.sqlite", deviceId: "dev-b"), account: account)

  let id = try a.store.upsert(clip("over the relay"))
  await a.syncNow()
  await b.syncNow()
  precondition(a.status.hasPrefix("Synced"), "A: \(a.status)")
  let ok149 = try b.store.recent(limit: 9).map(\.id) == [id]
  precondition(ok149, "B got the clip: \(b.status)")
  try b.store.clearHistory()
  await b.syncNow()
  await a.syncNow()
  let ok154 = try a.store.recent(limit: 9).isEmpty
  precondition(ok154, "A saw the delete")

  var req = URLRequest(url: account.base)
  req.httpMethod = "DELETE"
  req.setValue("Bearer \(account.authToken)", forHTTPHeaderField: "Authorization")
  _ = try await URLSession.shared.data(for: req)
  print("relay sync passed:", relay.absoluteString)
}

/// Cross-device check: pushes "from mac", prints the pairing link, then waits (≤ 3 min) for
/// another device on that link to push "from android". `Kopumi --check-sync-pair <relay URL>`
@MainActor
func checkSyncPair(_ relay: URL) async throws {
  let account = SyncAccount.create(relay: relay)
  let path = NSTemporaryDirectory() + "kopumi-pair-\(UUID()).sqlite"
  defer { try? FileManager.default.removeItem(atPath: path) }
  let mac = Sync(store: try Store(path: path, deviceId: "dev-mac"), account: account)
  try mac.store.upsert(clip("from mac"))
  await mac.syncNow()
  print("LINK", account.link)
  fflush(stdout)
  for _ in 0..<180 {
    try await Task.sleep(for: .seconds(1))
    await mac.syncNow()
    let texts = try mac.store.recent(limit: 9).compactMap(\.text)
    if texts.contains("from android") {
      print("pair sync passed:", texts)
      return
    }
  }
  throw SyncError("no clip from the other device")
}
