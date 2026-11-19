// App entry: wiring, menu bar item, and the clip history menu.
import AppKit

if CommandLine.arguments.contains("--check") {
  Task {
    do {
      try runChecks()
      try await checkCloud()
      exit(0)
    } catch {
      print("check failed:", error)
      exit(1)
    }
  }
  dispatchMain()
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
  do {
    try snapshotPanel(to: CommandLine.arguments[i + 1])
    try snapshotLivePanel(to: CommandLine.arguments[i + 1])
    exit(0)
  } catch {
    print("snapshot failed:", error)
    exit(1)
  }
}
if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
  do {
    try renderIcon(to: CommandLine.arguments[i + 1])
    exit(0)
  } catch {
    print("icon failed:", error)
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
  var onPauseChange: () -> Void = {}

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
      let item = add(c.label, #selector(pasteClip(_:)), key: i < 9 ? "\(i + 1)" : "")
      item.representedObject = c.id
      item.image = NSImage(
        systemSymbolName: c.sensitive ? "lock" : c.kind.symbol,
        accessibilityDescription: c.kind.rawValue)
      if !c.sensitive, let t = c.text { item.toolTip = String(t.prefix(500)) }
    }
    menu.addItem(.separator())
    if let until = Prefs.pausedUntil, Prefs.isPaused {
      let note =
        until == .distantFuture
        ? "" : " (paused until \(until.formatted(date: .omitted, time: .shortened)))"
      add("Resume Capture" + note, #selector(resume))
    } else {
      add("Pause for 1 Hour", #selector(pauseHour))
      add("Pause Until Resumed", #selector(pauseIndefinitely))
    }
    add("Clear History", #selector(clearHistory))
    menu.addItem(.separator())
    add("Settings…", #selector(openSettings), key: ",")
    menu.addItem(
      withTitle: "Quit Kopumi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  @discardableResult
  private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
    item.target = self
    return item
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
  @objc func openSettings() { Windows.show("settings", title: "Kopumi Settings", SettingsView()) }
  @objc func pauseHour() { setPause(Date().addingTimeInterval(3600)) }
  @objc func pauseIndefinitely() { setPause(.distantFuture) }
  @objc func resume() { setPause(nil) }

  private func setPause(_ until: Date?) {
    Prefs.pausedUntil = until
    onPauseChange()
  }
}

let menuController = MenuController(store: store)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(
  systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Kopumi")
statusItem.menu = menuController.menu
/// Dimmed icon = capture paused. Re-checked every 30 s so a 1-hour pause un-dims by itself.
@MainActor func refreshStatusIcon() { statusItem.button?.appearsDisabled = Prefs.isPaused }
menuController.onPauseChange = refreshStatusIcon
refreshStatusIcon()
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
  MainActor.assumeIsolated { refreshStatusIcon() }
}
Windows.installEditMenu()
Windows.applyAppearance()

let embedder = Embedder()
let enricher = Enricher(store: store, embedder: embedder)
let panelController = PanelController(store: store, embedder: embedder)
let watcher = Watcher(store: store)
watcher.onChange = { enricher.kick() }
watcher.start()
enricher.kick()  // backfill anything not enriched yet
KeyTap.onHold = { panelController.show() }
KeyTap.onDoubleCopy = { watcher.appendLatest() }

// History works without the tap; the Cmd+V panel, pasting and double Cmd+C need it.
// Without Accessibility access, explain why and keep retrying until it's granted.
if !KeyTap.start() {
  Windows.show("onboarding", title: "", chromeless: true, OnboardingView())
  Task {
    while !KeyTap.start() { try? await Task.sleep(for: .seconds(1.5)) }
    Windows.close("onboarding")
  }
}

NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon
NSApplication.shared.run()
