import Foundation
import NaturalLanguage
import Vision

/// On-device sentence embeddings (NLContextualEmbedding, one model per script: Latin, Cyrillic, …).
actor Embedder {
    private var models: [String: NLContextualEmbedding] = [:]  // by modelIdentifier

    /// Embeds a clip with the model for its language.
    func embed(_ text: String) async -> (model: String, vector: [Float])? {
        let text = String(text.prefix(2000))
        let lang = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        guard let fresh = NLContextualEmbedding(language: lang) ?? NLContextualEmbedding(language: .english),
              let model = await load(fresh),
              let v = vector(model, text, lang) else { return nil }
        return (model.modelIdentifier, v)
    }

    /// Embeds a search query with a specific model, so it's comparable with clips from that model.
    func embed(_ text: String, modelID: String) async -> [Float]? {
        guard let fresh = models[modelID] ?? NLContextualEmbedding(modelIdentifier: modelID),
              let model = await load(fresh) else { return nil }
        return vector(model, text, nil)
    }

    private func load(_ m: NLContextualEmbedding) async -> NLContextualEmbedding? {
        if let cached = models[m.modelIdentifier] { return cached }
        if !m.hasAvailableAssets {  // first use of a script downloads its model (once, system-wide)
            let ok = await withCheckedContinuation { c in
                m.requestAssets { result, _ in c.resume(returning: result == .available) }
            }
            guard ok else { return nil }
        }
        do { try m.load() } catch { print("embedding model:", error); return nil }
        models[m.modelIdentifier] = m
        return m
    }

    /// Mean-pooled token vectors, L2-normalised (so cosine similarity = dot product).
    private func vector(_ m: NLContextualEmbedding, _ text: String, _ lang: NLLanguage?) -> [Float]? {
        guard let r = try? m.embeddingResult(for: text, language: lang) else { return nil }
        var sum = [Double](repeating: 0, count: m.dimension)
        var n = 0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in v.indices where i < sum.count { sum[i] += v[i] }
            n += 1
            return true
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 && norm > 0 ? sum.map { Float($0 / norm) } : nil
    }
}

enum OCR {
    @concurrent
    static func text(_ image: Data) async -> String? {
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.automaticallyDetectsLanguage = true
        guard let obs = try? await req.perform(on: image) else { return nil }
        let s = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return s.isEmpty ? nil : s
    }
}

/// Slow, async enrichment after capture: OCR for images, an embedding for search by meaning,
/// and an on-device title for long clips. Secrets are never enriched.
@MainActor
final class Enricher {
    let store: Store
    let embedder: Embedder
    private var running = false

    init(store: Store, embedder: Embedder) {
        self.store = store
        self.embedder = embedder
    }

    func kick() {
        guard !running else { return }  // the running loop re-queries the DB, so it picks up new clips
        running = true
        Task {
            await drain()
            running = false
        }
    }

    private func drain() async {
        while let job = (try? store.nextToEnrich()) ?? nil {
            let clip = job.clip
            var title: String?, ocr: String?, embedding: (model: String, vector: [Float])?
            if !clip.sensitive {
                if clip.kind == .image, let data = job.blobs.first?.data {
                    ocr = await OCR.text(data)
                    if let line = ocr?.split(whereSeparator: \.isNewline).first {
                        title = "Image — " + line.prefix(50)
                    }
                }
                if let body = clip.text ?? ocr, !body.isEmpty {
                    embedding = await embedder.embed(body)
                }
                if let text = clip.text, needsTitle(clip.kind, text) {
                    title = await OnDeviceAI.title(for: text)
                }
            }
            do {
                try store.saveEnrichment(id: clip.id, title: title, ocr: ocr, embedding: embedding)
            } catch {
                print("enrich:", error)
                return  // don't spin on a DB error
            }
        }
    }
}

/// Long or multi-line clips get a generated title; short ones are their own title.
func needsTitle(_ kind: ClipKind, _ text: String) -> Bool {
    [.text, .code, .json, .table].contains(kind)
        && (text.count > 200 || text.split(whereSeparator: \.isNewline).count > 3)
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
func semanticSearch(_ q: SearchQuery, store: Store, embedder: Embedder, limit: Int) async -> [Clip] {
    guard let models = try? store.embeddingModels(), !models.isEmpty else { return [] }
    var scored: [(id: String, score: Float)] = []
    for m in models {
        guard let qv = await embedder.embed(q.text, modelID: m), let rows = try? store.embeddings(model: m) else { continue }
        scored += rows.map { row in (row.id, zip(qv, row.vector).reduce(0) { $0 + $1.0 * $1.1 }) }
    }
    let ids = scored.filter { $0.score >= 0.3 }.sorted { $0.score > $1.score }.prefix(limit * 3).map(\.id)
    let today = SearchQuery.startOfToday()
    return Array(((try? store.clips(ids: ids)) ?? []).filter { q.matches($0, startOfToday: today) }.prefix(limit))
}
