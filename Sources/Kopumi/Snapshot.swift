// Dev tool: `Kopumi --snapshot <dir>` renders the panel offscreen to PNGs (light/dark, two states).
import AppKit
import SwiftUI

@MainActor
func snapshotPanel(to dir: String) throws {
  let path = NSTemporaryDirectory() + "kopumi-snapshot-\(UUID()).sqlite"
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try Store(path: path, deviceId: "snapshot")
  let samples: [(ClipKind, String, String)] = [
    (.url, "https://developer.apple.com/documentation/foundationmodels", "com.apple.Safari"),
    (.color, "#1C1C1E", "com.figma.Desktop"),
    (
      .code,
      "SELECT u.name, count(o.id)\nFROM users u\nJOIN orders o ON o.user_id = u.id\nGROUP BY u.name\nORDER BY 2 DESC;",
      "com.apple.dt.Xcode"
    ),
    (
      .json, #"{"id": 42, "name": "Kopumi", "tags": ["clipboard", "macOS"]}"#,
      "com.microsoft.VSCode"
    ),
    (.email, "hello@example.com", "com.apple.mail"),
    (
      .text,
      "hi team, i think we shoud move the launch to friday so design has time to finish the onboarding screens",
      "com.tinyspeck.slackmacgap"
    ),
  ]
  for (i, s) in samples.enumerated() {
    try store.upsert(
      NewClip(kind: s.0, text: s.1, sourceApp: s.2, contentHash: "s\(i)"),
      now: nowMs() - Int64(i) * 600_000)
  }
  let model = PanelModel(store: store, embedder: Embedder())
  model.reset()
  try render(PanelView(model: model), "\(dir)/panel-light.png", .aqua)
  try render(PanelView(model: model), "\(dir)/panel-dark.png", .darkAqua)
  model.selection = model.clips.firstIndex { $0.kind == .text } ?? 0  // text clips have AI actions
  model.toggleActions()
  model.move(1)
  try render(PanelView(model: model), "\(dir)/panel-actions-light.png", .aqua)
  try render(PanelView(model: model), "\(dir)/panel-actions-dark.png", .darkAqua)
  try render(SettingsView(), "\(dir)/settings-light.png", .aqua)
  try render(SettingsView(), "\(dir)/settings-dark.png", .darkAqua)
  try render(OnboardingView(), "\(dir)/onboarding-light.png", .aqua)
  if let i = model.actions.firstIndex(where: { $0.id == "cloud.summarize" }) {
    model.runAction(i)  // first use of a cloud action → asks before sending
    try render(PanelView(model: model), "\(dir)/panel-consent-light.png", .aqua)
  }
}

@MainActor
private func render(_ root: some View, _ file: String, _ appearance: NSAppearance.Name) throws {
  let view = NSHostingView(rootView: root)
  view.frame = NSRect(origin: .zero, size: view.fittingSize)
  let window = NSWindow(
    contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: appearance)
  window.contentView = view
  view.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.4))  // let SwiftUI lay out and draw
  guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
  view.cacheDisplay(in: view.bounds, to: rep)
  try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
  print("wrote", file)
}

/// `Kopumi --icon <file.png>`: the 1024 px app icon master (run.sh turns it into AppIcon.icns).
@MainActor
func renderIcon(to file: String) throws {
  let renderer = ImageRenderer(content: IconView().frame(width: 1024, height: 1024))
  guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
  else { throw CloudError(message: "icon render failed") }
  try png.write(to: URL(fileURLWithPath: file))
  print("wrote", file)
}

/// Dark tile; a clip stacked on another, with one solid line (the panel's inverted selection).
private struct IconView: View {
  private let ink = Color(white: 0.08)
  private let paper = Color(white: 0.95)

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous).fill(ink)
        .frame(width: 824, height: 824)
      card.opacity(0.35).offset(x: -46, y: -46)
      card.background(ink).offset(x: 46, y: 46)
        .overlay(lines.offset(x: 46, y: 46))
    }
  }

  private var card: some View {
    RoundedRectangle(cornerRadius: 22, style: .continuous)
      .strokeBorder(paper, lineWidth: 22)
      .frame(width: 360, height: 440)
  }

  private var lines: some View {
    VStack(alignment: .leading, spacing: 46) {
      Capsule().fill(paper).frame(width: 220, height: 22)
      RoundedRectangle(cornerRadius: 6).fill(paper).frame(width: 236, height: 56)  // the selection
      Capsule().fill(paper).frame(width: 170, height: 22)
    }
    .frame(width: 236, alignment: .leading)
  }
}
