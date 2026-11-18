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
  try render(model, "\(dir)/panel-light.png", .aqua)
  try render(model, "\(dir)/panel-dark.png", .darkAqua)
  model.selection = model.clips.firstIndex { $0.kind == .text } ?? 0  // text clips have AI actions
  model.toggleActions()
  model.move(1)
  try render(model, "\(dir)/panel-actions-light.png", .aqua)
  try render(model, "\(dir)/panel-actions-dark.png", .darkAqua)
  if let i = model.actions.firstIndex(where: { $0.id == "cloud.summarize" }) {
    model.runAction(i)  // first use of a cloud action → asks before sending
    try render(model, "\(dir)/panel-consent-light.png", .aqua)
  }
}

@MainActor
private func render(_ model: PanelModel, _ file: String, _ appearance: NSAppearance.Name) throws {
  let view = NSHostingView(rootView: PanelView(model: model))
  view.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
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
