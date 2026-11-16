// Background enrichment: embeddings, OCR, and on-device titles for stored clips.
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
    guard
      let fresh = NLContextualEmbedding(language: lang)
        ?? NLContextualEmbedding(language: .english),
      let model = await load(fresh),
      let v = vector(model, text, lang)
    else { return nil }
    return (model.modelIdentifier, v)
  }

  /// Embeds a search query with a specific model, so it's comparable with clips from that model.
  func embed(_ text: String, modelID: String) async -> [Float]? {
    guard let fresh = models[modelID] ?? NLContextualEmbedding(modelIdentifier: modelID),
      let model = await load(fresh)
    else { return nil }
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
    do { try m.load() } catch {
      print("embedding model:", error)
      return nil
    }
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
      do {
        try await enrich(job.clip, image: job.blobs.first?.data)
      } catch {
        print("enrich:", error)
        return  // don't spin on a DB error
      }
    }
  }

  private func enrich(_ clip: Clip, image: Data?) async throws {
    guard !clip.sensitive else {
      return try store.saveEnrichment(id: clip.id, title: nil, ocr: nil, embedding: nil)
    }
    var title: String?
    var ocr: String?
    if clip.kind == .image, let image {
      ocr = await OCR.text(image)
      title = ocr?.split(whereSeparator: \.isNewline).first.map { "Image — " + $0.prefix(50) }
    }
    var embedding: (model: String, vector: [Float])?
    if let body = clip.text ?? ocr, !body.isEmpty {
      embedding = await embedder.embed(body)
    }
    if let text = clip.text, needsTitle(clip.kind, text) {
      title = await OnDeviceAI.title(for: text)
    }
    try store.saveEnrichment(id: clip.id, title: title, ocr: ocr, embedding: embedding)
  }
}

/// Long or multi-line clips get a generated title; short ones are their own title.
func needsTitle(_ kind: ClipKind, _ text: String) -> Bool {
  [.text, .code, .json, .table].contains(kind)
    && (text.count > 200 || text.split(whereSeparator: \.isNewline).count > 3)
}
