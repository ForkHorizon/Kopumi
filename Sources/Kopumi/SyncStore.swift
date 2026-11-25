// Store side of sync: the record format, local changes to push, and applying remote records
// (last writer wins + the same-content rule). Protocol: protocol/SYNC.md
import Foundation
import SQLite3

/// One clip as it travels between devices (encrypted). Missing optional fields mean null.
struct SyncRecord: Codable, Equatable {
  // periphery:ignore - format version, only written to the wire for other clients
  var v: Int? = 1
  var id: String
  var createdAt: Int64
  var updatedAt: Int64
  var lastUsedAt: Int64
  var deviceId: String
  var kind: String
  var sourceApp: String?
  var text: String?
  var title: String?
  var meta: String?
  var contentHash: String
  var pinned: Bool
  var derivedFrom: String?
  var deleted: Bool

  /// (updatedAt, deviceId) order; the greater version wins everywhere.
  func isNewer(than ts: Int64, _ dev: String) -> Bool {
    updatedAt > ts || (updatedAt == ts && deviceId > dev)
  }

  mutating func makeTombstone() {
    deleted = true
    text = nil
    title = nil
    meta = nil
    contentHash = "deleted:" + id
  }
}

extension Store {
  private static let syncCols = """
    id, createdAt, updatedAt, lastUsedAt, deviceId, kind, sourceApp, text, title, meta,
    contentHash, pinned, derivedFrom, deleted
    """

  /// Clips changed here since the last push. Secrets never leave the device.
  func pendingSync(limit: Int) throws -> [SyncRecord] {
    var out: [SyncRecord] = []
    try run(
      "SELECT \(Self.syncCols) FROM clips WHERE dirty=1 AND sensitive=0 ORDER BY updatedAt LIMIT ?",
      [limit]
    ) { st in
      out.append(
        SyncRecord(
          id: self.text(st, 0)!, createdAt: sqlite3_column_int64(st, 1),
          updatedAt: sqlite3_column_int64(st, 2), lastUsedAt: sqlite3_column_int64(st, 3),
          deviceId: self.text(st, 4)!, kind: self.text(st, 5)!, sourceApp: self.text(st, 6),
          text: self.text(st, 7), title: self.text(st, 8), meta: self.text(st, 9),
          contentHash: self.text(st, 10)!, pinned: sqlite3_column_int(st, 11) != 0,
          derivedFrom: self.text(st, 12), deleted: sqlite3_column_int(st, 13) != 0))
    }
    return out
  }

  /// Clears dirty for pushed rows, unless they changed again while the push was in flight.
  func markSynced(_ records: [SyncRecord]) throws {
    for r in records {
      try run("UPDATE clips SET dirty=0 WHERE id=? AND updatedAt=?", [r.id, r.updatedAt])
    }
  }

  /// Everything goes up again (new account after "unpair all").
  func markAllDirty() throws { try run("UPDATE clips SET dirty=1") }

  /// Applies a record from another device. Returns true if anything changed here.
  @discardableResult
  func applyRemote(_ remote: SyncRecord, now: Int64 = nowMs()) throws -> Bool {
    var local: (ts: Int64, dev: String)?
    try run("SELECT updatedAt, deviceId FROM clips WHERE id=?", [remote.id]) {
      local = (sqlite3_column_int64($0, 0), self.text($0, 1)!)
    }
    if let local, !remote.isNewer(than: local.ts, local.dev) { return false }
    var r = remote
    if r.deleted { r.makeTombstone() }
    var dirty = false
    try run("BEGIN")
    do {
      if !r.deleted {
        var twin: (id: String, ts: Int64)?
        try run(
          "SELECT id, updatedAt FROM clips WHERE contentHash=? AND id<>? AND deleted=0",
          [r.contentHash, r.id]
        ) { twin = (self.text($0, 0)!, sqlite3_column_int64($0, 1)) }
        if let twin {  // same content on both devices: the smaller id stays
          if twin.id < r.id {
            r.makeTombstone()
            r.updatedAt = max(now, r.updatedAt + 1)
            dirty = true
          } else {
            try tombstone(where: "id=?", [twin.id], now: max(now, twin.ts + 1))
          }
        }
      }
      try run(
        """
        INSERT INTO clips(\(Self.syncCols), sensitive, dirty) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
        ON CONFLICT(id) DO UPDATE SET
          createdAt=excluded.createdAt, updatedAt=excluded.updatedAt,
          lastUsedAt=excluded.lastUsedAt, deviceId=excluded.deviceId, kind=excluded.kind,
          sourceApp=excluded.sourceApp, text=excluded.text, title=excluded.title,
          meta=excluded.meta, contentHash=excluded.contentHash, pinned=excluded.pinned,
          derivedFrom=excluded.derivedFrom, deleted=excluded.deleted, dirty=excluded.dirty,
          ocr=CASE WHEN clips.text IS excluded.text THEN clips.ocr ELSE NULL END,
          enrichedAt=CASE WHEN clips.text IS excluded.text THEN clips.enrichedAt ELSE NULL END
        """,
        [
          r.id, r.createdAt, r.updatedAt, r.lastUsedAt, r.deviceId, r.kind, r.sourceApp, r.text,
          r.title, r.meta, r.contentHash, r.pinned, r.derivedFrom, r.deleted, dirty,
        ])
      if r.deleted {
        try run("DELETE FROM blobs WHERE clipId=?", [r.id])
        try run("DELETE FROM embeddings WHERE clipId=?", [r.id])
      }
      try run("COMMIT")
    } catch {
      try? run("ROLLBACK")
      throw error
    }
    return true
  }

  func kv(_ key: String) throws -> String? {
    var v: String?
    try run("SELECT value FROM kv WHERE key=?", [key]) { v = self.text($0, 0) }
    return v
  }

  func setKV(_ key: String, _ value: String?) throws {
    if let value {
      try run("INSERT OR REPLACE INTO kv(key, value) VALUES(?,?)", [key, value])
    } else {
      try run("DELETE FROM kv WHERE key=?", [key])
    }
  }
}
