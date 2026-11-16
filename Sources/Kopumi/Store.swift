import Foundation
import SQLite3

typealias Blob = (uti: String, data: Data)

struct Clip {
    let id: String
    let kind: ClipKind
    let text: String?
    let title: String?
    let sourceApp: String?
    let sensitive: Bool
    let lastUsedAt: Int64

    /// One-line title for menus and lists.
    var label: String {
        if sensitive { return "•••••••• secret (auto-deletes)" }
        if let title, !title.isEmpty { return title }
        let line: String
        switch kind {
        case .image: line = "Image"
        case .files:
            line = (text ?? "").split(separator: "\n").map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default:
            line = (text ?? "").split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return line.count > 60 ? line.prefix(60) + "…" : line
    }
}

struct NewClip {
    var kind: ClipKind
    var text: String?
    var sourceApp: String?
    var meta: [String: String] = [:]
    var contentHash: String
    var sensitive = false
    var blobs: [Blob] = []
    var derivedFrom: String?
}

/// Search box syntax: free text plus `type:url`, `app:xcode`, `is:today`.
struct SearchQuery: Equatable {
    var text = ""
    var kind: ClipKind?
    var app: String?
    var today = false

    init(_ raw: String) {
        var words: [Substring] = []
        for w in raw.split(whereSeparator: \.isWhitespace) {
            let lw = w.lowercased()
            if lw.hasPrefix("type:"), let k = ClipKind(rawValue: String(lw.dropFirst(5))) { kind = k }
            else if lw.hasPrefix("app:"), lw.count > 4 { app = String(lw.dropFirst(4)) }
            else if lw == "is:today" { today = true }
            else { words.append(w) }
        }
        text = words.joined(separator: " ")
    }

    func matches(_ c: Clip, startOfToday: Int64) -> Bool {
        (kind == nil || c.kind == kind)
            && (app == nil || (c.sourceApp ?? "").lowercased().contains(app!))
            && (!today || c.lastUsedAt >= startOfToday)
    }

    static func startOfToday() -> Int64 {
        Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
    }
}

struct DBError: Error { let message: String }

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Time-sortable id (UUIDv7) — globally unique, safe for future sync.
func uuidv7(now: Int64 = nowMs()) -> String {
    var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
    for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: now >> (40 - 8 * i)) }
    b[6] = (b[6] & 0x0F) | 0x70
    b[8] = (b[8] & 0x3F) | 0x80
    return NSUUID(uuidBytes: b).uuidString.lowercased()
}

extension Array where Element == Float {
    var data: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
    init(data: Data) { self = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
}

/// ponytail: one connection on the main thread; heavy work (OCR, models) runs elsewhere and only
/// reads/writes come back here. Move to an actor if queries ever show up in a profile.
@MainActor
final class Store {
    static let sensitiveTTL: Int64 = 10 * 60 * 1000
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let deviceId: String

    /// Append-only: index i upgrades user_version i → i+1. Never edit a shipped entry.
    private static let migrations = [
        // v1: enrichment (OCR, title, embeddings) + FTS over text/title/ocr
        """
        ALTER TABLE clips ADD COLUMN ocr TEXT;
        ALTER TABLE clips ADD COLUMN enrichedAt INTEGER;
        DROP TRIGGER IF EXISTS clips_fts_ai; DROP TRIGGER IF EXISTS clips_fts_ad; DROP TRIGGER IF EXISTS clips_fts_au;
        DROP TABLE IF EXISTS clips_fts;
        CREATE VIRTUAL TABLE clips_fts USING fts5(
          text, title, ocr, content='clips', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER clips_fts_ai AFTER INSERT ON clips BEGIN
          INSERT INTO clips_fts(rowid, text, title, ocr) VALUES (new.rowid, new.text, new.title, new.ocr);
        END;
        CREATE TRIGGER clips_fts_ad AFTER DELETE ON clips BEGIN
          INSERT INTO clips_fts(clips_fts, rowid, text, title, ocr) VALUES ('delete', old.rowid, old.text, old.title, old.ocr);
        END;
        CREATE TRIGGER clips_fts_au AFTER UPDATE OF text, title, ocr ON clips BEGIN
          INSERT INTO clips_fts(clips_fts, rowid, text, title, ocr) VALUES ('delete', old.rowid, old.text, old.title, old.ocr);
          INSERT INTO clips_fts(rowid, text, title, ocr) VALUES (new.rowid, new.text, new.title, new.ocr);
        END;
        CREATE TABLE embeddings(clipId TEXT PRIMARY KEY, model TEXT NOT NULL, vec BLOB NOT NULL);
        CREATE INDEX embeddings_model ON embeddings(model);
        """,
    ]

    init(path: String, deviceId: String) throws {
        self.deviceId = deviceId
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw DBError(message: "open \(path)") }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS clips(
              id TEXT PRIMARY KEY,
              createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, lastUsedAt INTEGER NOT NULL,
              deviceId TEXT NOT NULL, kind TEXT NOT NULL, sourceApp TEXT,
              text TEXT, title TEXT, meta TEXT,
              contentHash TEXT NOT NULL UNIQUE,
              pinned INTEGER NOT NULL DEFAULT 0, sensitive INTEGER NOT NULL DEFAULT 0,
              expiresAt INTEGER, derivedFrom TEXT,
              deleted INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS clips_recent ON clips(deleted, lastUsedAt DESC);
            CREATE TABLE IF NOT EXISTS blobs(
              clipId TEXT NOT NULL, uti TEXT NOT NULL, data BLOB NOT NULL,
              PRIMARY KEY(clipId, uti));
            """)
        var version = 0
        try run("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        for (i, sql) in Self.migrations.enumerated() where i >= version {
            try exec("BEGIN; \(sql) PRAGMA user_version = \(i + 1); COMMIT;")
        }
        // ponytail: full rebuild each launch keeps the index honest (rowids can move); O(history), fine to ~100k.
        try exec("INSERT INTO clips_fts(clips_fts) VALUES ('rebuild');")
    }

    /// Insert, or bump the existing row if the same content was copied before. Returns the clip id.
    @discardableResult
    func upsert(_ c: NewClip, now: Int64 = nowMs()) throws -> String {
        let meta = c.meta.isEmpty ? nil : String(data: try JSONEncoder().encode(c.meta), encoding: .utf8)
        var id = uuidv7(now: now)
        try run("BEGIN")
        do {
            try run("""
                INSERT INTO clips(id, createdAt, updatedAt, lastUsedAt, deviceId, kind, sourceApp, text, meta,
                                  contentHash, sensitive, expiresAt, derivedFrom)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(contentHash) DO UPDATE SET
                  lastUsedAt=excluded.lastUsedAt, updatedAt=excluded.updatedAt,
                  sourceApp=excluded.sourceApp, expiresAt=excluded.expiresAt
                RETURNING id
                """,
                [id, now, now, now, deviceId, c.kind.rawValue, c.sourceApp, c.text, meta, c.contentHash,
                 c.sensitive, c.sensitive ? now + Self.sensitiveTTL : nil, c.derivedFrom]) { id = self.text($0, 0)! }
            for b in c.blobs {
                try run("INSERT OR REPLACE INTO blobs(clipId, uti, data) VALUES(?,?,?)", [id, b.uti, b.data])
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
        return id
    }

    func recent(limit: Int) throws -> [Clip] { try search(SearchQuery(""), limit: limit) }

    func search(_ query: String, limit: Int) throws -> [Clip] { try search(SearchQuery(query), limit: limit) }

    /// Keyword search (word-prefix match over text, title, OCR) + filters, newest first.
    func search(_ q: SearchQuery, limit: Int) throws -> [Clip] {
        var from = "clips", conds = ["clips.deleted=0"], args: [Any?] = []
        let words = q.text.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty {
            from = "clips_fts JOIN clips ON clips.rowid = clips_fts.rowid"
            conds.append("clips_fts MATCH ?")
            args.append(words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " "))
        }
        if let k = q.kind { conds.append("clips.kind=?"); args.append(k.rawValue) }
        if let a = q.app { conds.append("clips.sourceApp LIKE ?"); args.append("%\(a)%") }
        if q.today { conds.append("clips.lastUsedAt >= ?"); args.append(SearchQuery.startOfToday()) }
        var out: [Clip] = []
        try run("""
            SELECT \(Self.cols) FROM \(from) WHERE \(conds.joined(separator: " AND "))
            ORDER BY clips.lastUsedAt DESC LIMIT ?
            """, args + [limit]) { out.append(self.clip($0)) }
        return out
    }

    func clip(id: String) throws -> Clip? { try clips(ids: [id]).first }

    /// Live clips for the given ids, in the given order.
    func clips(ids: [String]) throws -> [Clip] {
        guard !ids.isEmpty else { return [] }
        var byId: [String: Clip] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try run("SELECT \(Self.cols) FROM clips WHERE deleted=0 AND id IN (\(marks))", ids) {
            let c = self.clip($0); byId[c.id] = c
        }
        return ids.compactMap { byId[$0] }
    }

    func blobs(id: String) throws -> [Blob] {
        var out: [Blob] = []
        try run("SELECT uti, data FROM blobs WHERE clipId=?", [id]) { st in
            out.append((self.text(st, 0)!, self.blob(st, 1)))
        }
        return out
    }

    func touch(id: String, now: Int64 = nowMs()) throws {
        try run("UPDATE clips SET lastUsedAt=?, updatedAt=? WHERE id=?", [now, now, id])
    }

    // MARK: - Enrichment

    /// Newest clip that hasn't been through the enricher yet.
    func nextToEnrich() throws -> (clip: Clip, blobs: [Blob])? {
        var c: Clip?
        try run("SELECT \(Self.cols) FROM clips WHERE deleted=0 AND enrichedAt IS NULL ORDER BY lastUsedAt DESC LIMIT 1") {
            c = self.clip($0)
        }
        guard let c else { return nil }
        return (c, c.kind == .image ? try blobs(id: c.id) : [])
    }

    func saveEnrichment(id: String, title: String?, ocr: String?, embedding: (model: String, vector: [Float])?,
                        now: Int64 = nowMs()) throws {
        try run("UPDATE clips SET title=coalesce(?, title), ocr=?, enrichedAt=? WHERE id=? AND deleted=0",
                [title, ocr, now, id])
        if let e = embedding {
            try run("""
                INSERT OR REPLACE INTO embeddings(clipId, model, vec)
                SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM clips WHERE id=? AND deleted=0)
                """, [id, e.model, e.vector.data, id])
        }
    }

    func embeddingModels() throws -> [String] {
        var out: [String] = []
        try run("SELECT DISTINCT model FROM embeddings") { out.append(self.text($0, 0)!) }
        return out
    }

    func embeddings(model: String) throws -> [(id: String, vector: [Float])] {
        var out: [(String, [Float])] = []
        try run("SELECT clipId, vec FROM embeddings WHERE model=?", [model]) {
            out.append((self.text($0, 0)!, [Float](data: self.blob($0, 1))))
        }
        return out
    }

    // MARK: - Deletion

    /// Deletes everything except pinned clips (tombstones keep ids for future sync).
    func clearHistory(now: Int64 = nowMs()) throws {
        try tombstone(where: "deleted=0 AND pinned=0", [], now: now)
    }

    /// Hard-deletes expired secrets (they never sync) and tombstones clips beyond `maxItems`.
    func prune(maxItems: Int, now: Int64 = nowMs()) throws {
        try run("DELETE FROM clips WHERE sensitive=1 AND expiresAt < ?", [now])
        try tombstone(where: """
            id IN (SELECT id FROM clips WHERE deleted=0 AND pinned=0 ORDER BY lastUsedAt DESC LIMIT -1 OFFSET ?)
            """, [maxItems], now: now)
    }

    // ponytail: tombstones pile up forever; purge old ones once sync defines "everyone has seen it".
    private func tombstone(where cond: String, _ args: [Any?], now: Int64) throws {
        try run("""
            UPDATE clips SET deleted=1, text=NULL, title=NULL, meta=NULL, ocr=NULL,
              contentHash='deleted:' || id, updatedAt=? WHERE \(cond)
            """, [now] + args)
        try run("DELETE FROM blobs WHERE clipId NOT IN (SELECT id FROM clips WHERE deleted=0)")
        try run("DELETE FROM embeddings WHERE clipId NOT IN (SELECT id FROM clips WHERE deleted=0)")
    }

    // MARK: - SQLite plumbing

    private static let cols =
        "clips.id, clips.kind, clips.text, clips.title, clips.sourceApp, clips.sensitive, clips.lastUsedAt"

    private func clip(_ st: OpaquePointer) -> Clip {
        Clip(id: text(st, 0)!, kind: ClipKind(rawValue: text(st, 1)!) ?? .text, text: text(st, 2), title: text(st, 3),
             sourceApp: text(st, 4), sensitive: sqlite3_column_int(st, 5) != 0, lastUsedAt: sqlite3_column_int64(st, 6))
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }

    private func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(st, i))
        return sqlite3_column_blob(st, i).map { Data(bytes: $0, count: n) } ?? Data()
    }

    private func error() -> DBError { DBError(message: String(cString: sqlite3_errmsg(db))) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let e = error()
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw e
        }
    }

    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw error() }
        defer { sqlite3_finalize(st) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(st, idx)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, transient)
            case let v as Bool: sqlite3_bind_int(st, idx, v ? 1 : 0)
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Data: v.withUnsafeBytes { _ = sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), transient) }
            default: preconditionFailure("unsupported bind type \(type(of: arg))")
            }
        }
        while true {
            switch sqlite3_step(st) {
            case SQLITE_ROW: row?(st)
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }
}
