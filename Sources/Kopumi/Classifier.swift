// Instant rule-based clip typing, secret detection, and context-aware paste rules.
import Foundation

enum ClipKind: String, CaseIterable {
  case text, url, email, phone, address, date, color, json, code, table, image, files

  var symbol: String {
    switch self {
    case .text: "text.alignleft"
    case .url: "link"
    case .email: "envelope"
    case .phone: "phone"
    case .address: "mappin.and.ellipse"
    case .date: "calendar"
    case .color: "paintpalette"
    case .json: "curlybraces"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .table: "tablecells"
    case .image: "photo"
    case .files: "doc"
    }
  }
}

struct Classification: Equatable {
  var kind: ClipKind
  var meta: [String: String] = [:]
}

let terminalApps: Set<String> = [
  "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
  "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
]
let editorApps: Set<String> = [
  "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
  "com.sublimetext.4", "com.panic.Nova",
]

func isCodeApp(_ bundle: String) -> Bool {
  terminalApps.contains(bundle) || editorApps.contains(bundle) || bundle.hasPrefix("com.jetbrains.")
}

enum PasteStyle: Equatable {
  case asCopied  // every representation we stored (rich text etc.)
  case plain  // string only
  case terminal  // string only, trailing newlines dropped so a paste never runs a command
}

// ponytail: no rich→Markdown conversion; Notion/Slack handle pasted HTML themselves. Add if a target needs it.
func pasteStyle(for bundle: String?, forcePlain: Bool) -> PasteStyle {
  guard let bundle else { return forcePlain ? .plain : .asCopied }
  if terminalApps.contains(bundle) { return .terminal }
  return forcePlain || isCodeApp(bundle) ? .plain : .asCopied
}

func pasteText(_ text: String, _ style: PasteStyle) -> String {
  guard style == .terminal else { return text }
  var t = Substring(text)
  while let last = t.last, last.isNewline { t.removeLast() }
  return String(t)
}

/// Instant, rule-based type detection. No LLM on the copy path.
func classify(_ raw: String, sourceApp: String? = nil) -> Classification {
  let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !s.isEmpty else { return .init(kind: .text) }

  if s.wholeMatch(of: /#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})/) != nil
    || s.wholeMatch(of: /(?:rgb|hsl)a?\(\s*[\d.%\s,\/]+\)/.ignoresCase()) != nil
  {
    return .init(kind: .color)
  }
  if let c = s.first, c == "{" || c == "[",
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
  {
    return .init(kind: .json)
  }
  if let m = wholeDataMatch(s) { return m }
  if isTable(s) { return .init(kind: .table) }
  if looksLikeCode(s, sourceApp: sourceApp) { return .init(kind: .code) }
  return .init(kind: .text)
}

/// URL / email / phone / address / date — only when the match covers the whole clip.
private func wholeDataMatch(_ s: String) -> Classification? {
  let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address, .date]
  guard let d = try? NSDataDetector(types: types.rawValue) else { return nil }
  let full = NSRange(s.startIndex..., in: s)
  guard let m = d.firstMatch(in: s, range: full), m.range == full else { return nil }
  switch m.resultType {
  case .link:
    guard let url = m.url else { return nil }
    if url.scheme == "mailto" { return .init(kind: .email) }
    return .init(kind: .url, meta: ["host": url.host ?? ""])
  case .phoneNumber: return .init(kind: .phone)
  case .address: return .init(kind: .address)
  case .date:
    guard let date = m.date else { return nil }
    return .init(kind: .date, meta: ["iso": ISO8601DateFormatter().string(from: date)])
  default: return nil
  }
}

/// ≥2 lines with the same number of non-leading tabs.
private func isTable(_ s: String) -> Bool {
  let lines = s.split(separator: "\n")
  guard lines.count >= 2, lines.allSatisfy({ $0.first != "\t" }) else { return false }
  let tabs = Set(lines.map { $0.filter { $0 == "\t" }.count })
  return tabs.count == 1 && tabs.first! > 0
}

// ponytail: marker heuristic, misfires on odd prose/code; swap for an on-device model in M3 if it bothers.
private let codeMarkers = [
  ";", "{", "}", "=>", "->", "==", "()", "</", "def ", "func ", "fn ", "class ",
  "import ", "return ", "const ", "let ", "var ", "SELECT ", "#include",
]

private func looksLikeCode(_ s: String, sourceApp: String?) -> Bool {
  let lines = s.split(whereSeparator: \.isNewline)
  if lines.count > 1, let app = sourceApp, isCodeApp(app) { return true }
  if lines.count == 1 { return codeMarkers.filter { s.contains($0) }.count >= 3 }
  let hits = lines.filter { l in codeMarkers.contains { l.contains($0) } }.count
  return Double(hits) / Double(lines.count) >= 0.5
}

/// Likely secret: API keys, tokens, private keys, card numbers.
func isSensitive(_ s: String) -> Bool {
  let patterns: [Regex<Substring>] = [
    /sk-[A-Za-z0-9_\-]{20,}/,
    /gh[pousr]_[A-Za-z0-9]{30,}/,
    /github_pat_[A-Za-z0-9_]{20,}/,
    /AKIA[0-9A-Z]{16}/,
    /xox[abprs]-[A-Za-z0-9\-]{10,}/,
    /eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/,
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  ]
  if patterns.contains(where: { s.contains($0) }) { return true }
  return s.matches(of: /\b(?:\d[ \-]?){12,18}\d\b/).contains {
    luhn(String($0.output.filter(\.isNumber)))
  }
}

func luhn(_ digits: String) -> Bool {
  guard digits.count >= 13 else { return false }
  var sum = 0
  for (i, ch) in digits.reversed().enumerated() {
    guard var d = ch.wholeNumberValue else { return false }
    if i % 2 == 1 {
      d *= 2
      if d > 9 { d -= 9 }
    }
    sum += d
  }
  return sum % 10 == 0
}
