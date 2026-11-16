// App entry: wiring, menu bar item, and the clip history menu.
import AppKit

if CommandLine.arguments.contains("--check") {
  do {
    try runChecks()
    exit(0)
  } catch {
    print("check failed:", error)
    exit(1)
  }
}
if CommandLine.arguments.contains("--check-ai") {  // real on-device models; no UI
  Task {
    await runAIChecks()
    exit(0)
  }
  dispatchMain()
}

let defaults = UserDefaults.standard
let deviceId =
  defaults.string(forKey: "deviceId")
  ?? {
    let id = uuidv7()
    defaults.set(id, forKey: "deviceId")
    return id
  }()
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Kopumi")
let store: Store
do {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  store = try Store(path: dir.appendingPathComponent("kopumi.sqlite").path, deviceId: deviceId)
} catch {
  fatalError("Cannot open history database: \(error)")
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  let store: Store

  init(store: Store) {
    self.store = store
    super.init()
    menu.delegate = self
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let clips = (try? store.recent(limit: 10)) ?? []
    if clips.isEmpty {
      menu.addItem(withTitle: "Nothing copied yet", action: nil, keyEquivalent: "").isEnabled =
        false
    }
    for (i, c) in clips.enumerated() {
      let item = NSMenuItem(
        title: c.label, action: #selector(pasteClip(_:)),
        keyEquivalent: i < 9 ? "\(i + 1)" : "")
      item.target = self
      item.representedObject = c.id
      item.image = NSImage(
        systemSymbolName: c.sensitive ? "lock.fill" : c.kind.symbol,
        accessibilityDescription: c.kind.rawValue)
      if !c.sensitive, let t = c.text { item.toolTip = String(t.prefix(500)) }
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let clear = NSMenuItem(
      title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
    menu.addItem(
      withTitle: "Quit Kopumi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  @objc func pasteClip(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let clip = try? store.clip(id: id) else {
      return
    }
    let blobs = (try? store.blobs(id: id)) ?? []
    try? store.touch(id: id)
    Paster.paste(clip, blobs: blobs)
  }

  @objc func clearHistory() { try? store.clearHistory() }
}

let menuController = MenuController(store: store)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(
  systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Kopumi")
statusItem.menu = menuController.menu

if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
  print("Grant Accessibility in System Settings → Privacy & Security, then relaunch.")
}
// History works without the tap; pasting from history and the Cmd+V panel need it.
let embedder = Embedder()
let enricher = Enricher(store: store, embedder: embedder)
let panelController = PanelController(store: store, embedder: embedder)
KeyTap.onHold = { panelController.show() }
if !KeyTap.start() { print("Event tap failed (no Accessibility permission?)") }

let watcher = Watcher(store: store)
watcher.onChange = { enricher.kick() }
watcher.start()
enricher.kick()  // backfill anything not enriched yet

NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon
NSApplication.shared.run()
