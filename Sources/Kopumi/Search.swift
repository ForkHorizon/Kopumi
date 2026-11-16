// Search: query syntax, meaning-based search, and merging of ranked results.
import Foundation

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
      if lw.hasPrefix("type:"), let k = ClipKind(rawValue: String(lw.dropFirst(5))) {
        kind = k
      } else if lw.hasPrefix("app:"), lw.count > 4 {
        app = String(lw.dropFirst(4))
      } else if lw == "is:today" {
        today = true
      } else {
        words.append(w)
      }
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

/// Reciprocal rank fusion: merges ranked id lists; items high in several lists win.
func fuse(_ lists: [[String]], k: Double = 60) -> [String] {
  var score: [String: Double] = [:]
  var firstSeen: [String: Int] = [:]
  for list in lists {
    for (rank, id) in list.enumerated() {
      score[id, default: 0] += 1 / (k + Double(rank + 1))
      if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
    }
  }
  return score.keys.sorted { a, b in
    score[a]! != score[b]! ? score[a]! > score[b]! : firstSeen[a]! < firstSeen[b]!
  }
}

/// Search by meaning: embed the query per model, cosine against stored clip vectors.
// ponytail: brute force over all vectors; fine to ~50k clips, add an ANN index past that.
@MainActor
func semanticSearch(_ q: SearchQuery, store: Store, embedder: Embedder, limit: Int) async -> [Clip]
{
  guard let models = try? store.embeddingModels(), !models.isEmpty else { return [] }
  var scored: [(id: String, score: Float)] = []
  for m in models {
    guard let qv = await embedder.embed(q.text, modelID: m),
      let rows = try? store.embeddings(model: m)
    else { continue }
    scored += rows.map { row in (row.id, zip(qv, row.vector).reduce(0) { $0 + $1.0 * $1.1 }) }
  }
  let ids = scored.filter { $0.score >= 0.3 }.sorted { $0.score > $1.score }.prefix(limit * 3).map(
    \.id)
  let today = SearchQuery.startOfToday()
  return Array(
    ((try? store.clips(ids: ids)) ?? []).filter { q.matches($0, startOfToday: today) }.prefix(limit)
  )
}
