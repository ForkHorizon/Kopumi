// End-to-end encrypted sync through the relay: keys, pairing link, push/pull loop, live socket.
// Protocol: protocol/SYNC.md
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation

private struct Envelope: Codable {
  var seq: Int64?
  let id: String
  let ts: Int64
  let dev: String
  let data: String
}

private struct PullReply: Decodable {
  let records: [Envelope]
  let seq: Int64
  let more: Bool
}

@MainActor
final class Sync: ObservableObject {
  static var shared: Sync?

  @Published private(set) var account: SyncAccount?
  @Published private(set) var status = "Off"
  let store: Store
  var onApplied: () -> Void = {}

  private var running = false
  private var again = false
  private var socket: URLSessionWebSocketTask?
  private var generation = 0  // bumps on account change so old loops stop

  init(store: Store, account: SyncAccount?) {
    self.store = store
    self.account = account
  }

  // MARK: account

  func use(_ a: SyncAccount?, persist: Bool = true) {
    if persist { SyncKeychain.save(a) }
    account = a
    generation += 1
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    status = a == nil ? "Off" : "Connecting…"
    start()
  }

  /// "Unpair all devices": wipe the old account on the relay, move this Mac to a fresh one.
  func rotate() async {
    guard let old = account else { return }
    var req = request(old, "", method: "DELETE")
    req.timeoutInterval = 15
    _ = try? await URLSession.shared.data(for: req)
    try? store.markAllDirty()
    use(.create(relay: old.relay))
  }

  // MARK: loop

  func start() {
    guard account != nil else { return }
    kick()
    listen(generation)
  }

  /// Run a sync soon; coalesces bursts.
  func kick() {
    guard account != nil else { return }
    if running {
      again = true
      return
    }
    Task { await syncNow() }
  }

  func syncNow() async {
    guard let a = account, !running else { return }
    running = true
    defer { running = false }
    repeat {
      again = false
      do {
        let applied = try await pull(a)
        let pushed = try await push(a)
        status = "Synced \(Date().formatted(date: .omitted, time: .shortened))"
        if applied > 0 { onApplied() }
        if pushed > 0 || applied > 0 { print("sync: pulled \(applied), pushed \(pushed)") }
      } catch {
        status = "Offline: \(error.localizedDescription)"
        return
      }
    } while again && account == a
  }

  private var cursorKey: String { "cursor:" + (account?.id ?? "") }

  private func pull(_ a: SyncAccount) async throws -> Int {
    var applied = 0
    var since = Int64(try store.kv(cursorKey) ?? "0") ?? 0
    while true {
      let reply: PullReply = try await call(
        request(a, "/records?since=\(since)&limit=500", method: "GET"))
      for e in reply.records {
        do {
          let r = try JSONDecoder().decode(SyncRecord.self, from: a.open(e.data, id: e.id))
          guard r.id == e.id else { throw SyncError("id mismatch") }
          if try store.applyRemote(r) { applied += 1 }
        } catch {
          print("sync: skipped \(e.id): \(error)")  // never block the cursor on one bad record
        }
      }
      since = reply.seq
      try store.setKV(cursorKey, String(since))
      if !reply.more { return applied }
    }
  }

  private func push(_ a: SyncAccount) async throws -> Int {
    var pushed = 0
    while true {
      let batch = try store.pendingSync(limit: 200)
      if batch.isEmpty { return pushed }
      let envelopes = try batch.map { r in
        Envelope(
          id: r.id, ts: r.updatedAt, dev: r.deviceId,
          data: try a.seal(try JSONEncoder().encode(r), id: r.id))
      }
      var req = request(a, "/records", method: "POST")
      req.httpBody = try JSONEncoder().encode(["records": envelopes])
      let _: [String: Int64] = try await call(req)
      try store.markSynced(batch)
      pushed += batch.count
    }
  }

  private func request(_ a: SyncAccount, _ path: String, method: String) -> URLRequest {
    var req = URLRequest(url: URL(string: a.base.absoluteString + path)!)
    req.httpMethod = method
    req.setValue("Bearer \(a.authToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 30
    return req
  }

  private func call<T: Decodable>(_ req: URLRequest) async throws -> T {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw SyncError(
        code == 401 || code == 410 ? "this device was unpaired" : "relay replied \(code)")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  // MARK: live socket

  /// Keeps a WebSocket open; every `{"seq":N}` hint triggers a sync. Reconnects with backoff.
  private func listen(_ gen: Int) {
    Task {
      var delay: Double = 2
      while gen == generation, let a = account {
        var url = URLComponents(url: a.base.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: url.url!)
        req.setValue("Bearer \(a.authToken)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        socket = ws
        ws.resume()
        do {
          while gen == generation {
            if case .string(let s) = try await ws.receive(), s.contains("\"seq\"") {
              delay = 2
              kick()
            }
          }
        } catch  where gen == generation {
          status = "Reconnecting…"  // socket dropped; the kick after the backoff sets it again
        } catch {
          ws.cancel()
          return  // sync was turned off or moved to another account
        }
        ws.cancel()
        guard gen == generation else { return }
        try? await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 60)
        kick()  // catch up on anything missed while disconnected
      }
    }
  }
}

/// QR code for the pairing link, crisp at `size` points.
func qrImage(_ text: String, size: CGFloat) -> CGImage? {
  let f = CIFilter.qrCodeGenerator()
  f.message = Data(text.utf8)
  f.correctionLevel = "M"
  guard let img = f.outputImage else { return nil }
  let scale = (size * 2 / img.extent.width).rounded(.down)
  return CIContext().createCGImage(
    img.transformed(by: .init(scaleX: scale, y: scale)),
    from: img.extent.applying(.init(scaleX: scale, y: scale)))
}
