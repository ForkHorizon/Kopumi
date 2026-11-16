// Clip actions: Apple's on-device model, the action catalog, and local text transforms.
import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models). Free, private, offline; small context window.
enum OnDeviceAI {
  static let actionInstructions = """
    You transform text the user copied. Reply with only the transformed text: no preamble, \
    no explanation, no surrounding quotes, no code fences unless the output is code. \
    Keep the original language unless the task says otherwise.
    """
  static let titleInstructions = """
    You write short titles for clipboard items. Reply with only the title: at most 8 words, \
    no quotes, no trailing period, in the same language as the content.
    """

  /// nil when the model can be used, else a human-readable reason.
  static var unavailableReason: String? {
    let availability = SystemLanguageModel.default.availability
    guard case .unavailable(let reason) = availability else { return nil }
    switch reason {
    case .appleIntelligenceNotEnabled:
      return "Turn on Apple Intelligence in System Settings to use AI actions."
    case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
    case .modelNotReady: return "Apple Intelligence model is still downloading — try again soon."
    @unknown default: return "On-device model unavailable (\(reason))."
    }
  }

  @concurrent
  static func respond(instructions: String, prompt: String) async throws -> String {
    let session = LanguageModelSession(instructions: instructions)
    return try await session.respond(to: prompt).content.trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  /// Short title for long clips; nil if the model is unavailable or declines.
  static func title(for text: String) async -> String? {
    guard unavailableReason == nil else { return nil }
    let t = try? await respond(
      instructions: titleInstructions, prompt: "Content:\n" + text.prefix(2500))
    return t.map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
  }

  static func describe(_ error: Error) -> String {
    if let e = error as? LanguageModelSession.GenerationError {
      switch e {
      case .exceededContextWindowSize:
        return "Too long for the on-device model. Cloud actions arrive in M4."
      case .guardrailViolation: return "Apple's on-device model declined this text."
      default: break
      }
    }
    return error.localizedDescription
  }
}

/// Something you can do to a clip from the panel. Actions are data, not classes.
struct ClipAction: Identifiable {
  enum Engine {
    case local(@Sendable (String) -> String?)  // instant, deterministic
    case onDevice(String)  // prompt for the on-device model
  }
  let id: String
  let title: String
  let symbol: String
  let kinds: Set<ClipKind>
  let engine: Engine

  static let all: [ClipAction] = [
    .init(
      id: "json.pretty", title: "Pretty-print JSON", symbol: "text.alignleft", kinds: [.json],
      engine: .local { formatJSON($0, pretty: true) }),
    .init(
      id: "json.minify", title: "Minify JSON", symbol: "arrow.down.right.and.arrow.up.left",
      kinds: [.json],
      engine: .local { formatJSON($0, pretty: false) }),
    .init(
      id: "url.clean", title: "Remove tracking parameters", symbol: "link", kinds: [.url],
      engine: .local(cleanURL)),
    .init(
      id: "color.rgb", title: "Convert to rgb()", symbol: "paintpalette", kinds: [.color],
      engine: .local(hexToRGB)),
    .init(
      id: "fix", title: "Fix grammar & spelling", symbol: "checkmark.circle", kinds: [.text],
      engine: .onDevice("Fix grammar, spelling and punctuation. Change nothing else.")),
    .init(
      id: "shorter", title: "Make shorter", symbol: "scissors", kinds: [.text],
      engine: .onDevice("Rewrite this to be about half as long, keeping every key fact.")),
    .init(
      id: "bullets", title: "Turn into bullet list", symbol: "list.bullet", kinds: [.text],
      engine: .onDevice("Turn this into a concise Markdown bullet list.")),
    .init(
      id: "formal", title: "More formal", symbol: "briefcase", kinds: [.text],
      engine: .onDevice("Rephrase in a more formal, professional tone.")),
    .init(
      id: "friendly", title: "Friendlier", symbol: "face.smiling", kinds: [.text],
      engine: .onDevice("Rephrase in a warmer, friendlier tone.")),
    .init(
      id: "extract", title: "Extract todos, dates & contacts", symbol: "checklist",
      kinds: [.text, .table],
      engine: .onDevice(
        """
        List every action item, date or deadline, person, email address and phone number in this text \
        as a Markdown list grouped by type. Omit empty groups.
        """)),
    .init(
      id: "swift", title: "JSON → Swift Codable", symbol: "swift", kinds: [.json],
      engine: .onDevice(
        "Write Swift Codable structs that decode this JSON. Output only Swift code.")),
  ]

  static func available(for clip: Clip) -> [ClipAction] {
    guard !clip.sensitive, clip.text != nil else { return [] }
    return all.filter { $0.kinds.contains(clip.kind) }
  }
}

// MARK: - Local transforms (pure)

// ponytail: JSONSerialization sorts keys (it can't keep the original order). Fine for pretty/minify.
func formatJSON(_ s: String, pretty: Bool) -> String? {
  guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed),
    let out = try? JSONSerialization.data(
      withJSONObject: obj,
      options: [
        .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed, pretty ? .prettyPrinted : [],
      ])
  else { return nil }
  return String(data: out, encoding: .utf8)
}

private let trackingParams: Set<String> = [
  "fbclid", "gclid", "dclid", "msclkid", "mc_eid", "igshid", "si", "ref_src",
]

func cleanURL(_ s: String) -> String? {
  guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    return nil
  }
  let kept = c.queryItems?.filter {
    !$0.name.lowercased().hasPrefix("utm_") && !trackingParams.contains($0.name)
  }
  c.queryItems = kept?.isEmpty == false ? kept : nil
  return c.string
}

func hexToRGB(_ s: String) -> String? {
  guard let c = hexRGBA(s) else { return nil }
  if c[3] == 255 { return "rgb(\(c[0]), \(c[1]), \(c[2]))" }
  return "rgba(\(c[0]), \(c[1]), \(c[2]), \(String(format: "%.2f", Double(c[3]) / 255)))"
}

/// "#rgb" / "#rrggbb" / "#rrggbbaa" → [r, g, b, a] in 0…255.
func hexRGBA(_ s: String) -> [Int]? {
  var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
  guard h.hasPrefix("#") else { return nil }
  h.removeFirst()
  if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
  guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
  let parts = h.count == 6 ? [v >> 16, v >> 8, v, 255] : [v >> 24, v >> 16, v >> 8, v]
  return parts.map { Int($0 & 255) }
}
